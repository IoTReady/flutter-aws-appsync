import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';

enum CachePriority {
  /// Use network if available, use cache as fallback.
  ///
  /// [AppSync.isNetworkError] is used to determine if an exception should be treated as a network error.
  ///
  /// If neither cache nor network is available, network errors will be not be caught.
  /// This is done to avoid a `null` return value.
  network,

  /// Use cache if available, use network as fallback.
  ///
  /// In this mode, network errors won't be caught at all.
  /// This is done to avoid a `null` return value.
  cache
}

class AppSync {
  final logger = Logger('AppSync');

  /// The duration after which cache is invalidated
  ///
  /// Set to 24 hours by default.
  ///
  /// If set to `null`, then cache will never expire.
  final Duration cacheExpiry;

  AppSync({this.cacheExpiry = const Duration(hours: 24)});

  /// Execute a GraphQL query with pagination.
  ///
  /// The query must accept the `limit` and `nextToken` variables.
  ///
  /// Internally, this delegates to [execute] in a loop to execute queries.
  /// Refer to its documentation.
  Stream<Map> paginate({
    @required String endpoint,
    int batchSize: 100,
    @required String query,
    @required Map variables,
    @required String accessToken,
    Database cache,
    CachePriority priority = CachePriority.network,
  }) async* {
    String nextToken;

    do {
      var data = await execute(
        endpoint: endpoint,
        query: query,
        variables: {
          "limit": batchSize,
          "nextToken": nextToken,
          ...variables,
        },
        accessToken: accessToken,
        cache: cache,
        priority: priority,
      );
      nextToken = extractNextToken(data);
      yield data;
    } while (nextToken != null);
  }

  String extractNextToken(Map data) {
    for (var item in data.values) {
      if (item is Map && item.containsKey('nextToken')) {
        return item["nextToken"];
      }
    }
    return null;
  }

  /// Execute a GraphQL query without pagination.
  ///
  /// Throws [HttpError] when appropriate.
  ///
  /// If [cache] is passed,
  /// then this will automatically call [readCache] and [updateCache] with that [Database].
  ///
  /// Use [priority] to control when and how cache should be used.
  /// This has no effect if [cache] is `null`.
  Future<Map> execute({
    @required String endpoint,
    @required String query,
    @required Map variables,
    @required String accessToken,
    Database cache,
    CachePriority priority = CachePriority.network,
  }) async {
    var body = jsonEncode({"query": query, "variables": variables});

    Future<Map> loadFromCache() async {
      var cacheKey = getCacheKey(endpoint, body);
      var data = await readCache(cache, cacheKey);
      if (data != null) {
        logger.fine(
          'loaded from cache (endpoint: ${endpoint.toRepr()}, requestBody: ${body.toRepr()}, cacheKey: $cacheKey)',
        );
      }
      return data;
    }

    if (cache != null && priority == CachePriority.cache) {
      var data = await loadFromCache();
      if (data != null) return data;
    }

    logger.fine('POST ${endpoint.toRepr()} - ${body.toRepr()}');

    http.Response response;
    try {
      response = await http.post(
        endpoint,
        headers: {
          HttpHeaders.authorizationHeader: accessToken,
          HttpHeaders.contentTypeHeader: ContentType.json.mimeType,
        },
        body: body,
      );
    } catch (e) {
      var shouldFallback = cache != null && priority == CachePriority.network;
      if (!shouldFallback || !isNetworkError(e)) rethrow;

      logger.finest('network error encountered; falling back to cache - $e');

      var data = await loadFromCache();
      if (data != null) {
        return data;
      } else {
        rethrow;
      }
    }

    if (response.statusCode != HttpStatus.ok) {
      throw HttpError(response);
    }

    logger.fine(
      'loaded from network (endpoint: ${endpoint.toRepr()}, requestBody: ${body.toRepr()})',
    );
    var result = jsonDecode(response.body);
    var data = result["data"];

    if (cache != null) {
      var cacheKey = getCacheKey(endpoint, body);
      await updateCache(cache, cacheKey, data);
      logger.fine(
        'updated cache (endpoint: ${endpoint.toRepr()}, requestBody: ${body.toRepr()}, cacheKey: $cacheKey)',
      );
    }

    return data;
  }

  /// Return whether [e] should be treated as a network error
  bool isNetworkError(dynamic e) => e is SocketException;

  /// Get a unique key for caching a request
  ///
  /// [endpoint] - same as [execute]'s parameter.
  /// [requestBody] - the HTTP request body.
  int getCacheKey(String endpoint, String requestBody) {
    return hashValues(endpoint, requestBody);
  }

  final _store = StoreRef.main();

  /// Read cache from [db] using [cacheKey].
  Future<Map> readCache(Database db, int cacheKey) async {
    var rec = _store.record(cacheKey);
    var entry = await rec.get(db) as Map;
    if (entry == null || isCacheEntryExpired(entry)) {
      return null;
    }
    return entry['data'];
  }

  /// Checks whether this cache [entry] is expired.
  bool isCacheEntryExpired(Map entry) {
    if (cacheExpiry != null) return false;

    var now = DateTime.now();
    var timestampMillis =
        entry['timestampMillis'] ?? now.millisecondsSinceEpoch;
    var dt = DateTime.fromMillisecondsSinceEpoch(timestampMillis);

    return now.difference(dt) > cacheExpiry;
  }

  /// Update cache with new data. Also invalidates stale cache as a bonus.
  Future<void> updateCache(Database db, int cacheKey, Map data) async {
    var now = DateTime.now();
    var entry = {'timestampMillis': now.millisecondsSinceEpoch, 'data': data};

    return await db.transaction((txn) async {
      await _store.record(cacheKey).put(txn, entry);
      await invalidateCache(txn);
    });
  }

  /// Delete cache entries older than [cacheExpiry].
  ///
  /// There's usually no need to call this manually - it is called automatically by [updateCache].
  Future<int> invalidateCache(DatabaseClient txn) async {
    if (cacheExpiry == null) return 0;

    var now = DateTime.now();
    var oldestValid = now.subtract(cacheExpiry).millisecondsSinceEpoch;

    var filter = Filter.lessThan('timestampMillis', oldestValid);
    var finder = Finder(filter: filter);

    var n = await _store.delete(txn, finder: finder);
    logger.finest('invalidated $n cache entries (cacheExpiry: $cacheExpiry)');

    return n;
  }

  /// Get database at `'root/aws_appsync_cache.db'`.
  /// By default, [root] is set to path_provider's [getTemporaryDirectory].
  Future<Database> getCacheDatabase({Directory root}) async {
    root ??= await getTemporaryDirectory();
    return databaseFactoryIo.openDatabase('${root.path}/aws_appync_cache.db');
  }
}

extension StringRepr on String {
  String toRepr() => "'" + replaceAll('\n', '\\n') + "'";
}

class HttpError implements Exception {
  final http.Response response;

  HttpError(this.response);

  @override
  String toString() {
    var repr = response.body.toRepr();
    return "$runtimeType ${response.statusCode} - $repr";
  }
}
