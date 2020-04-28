import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';

class AppSync {
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
  /// If [cache] is passed,
  /// then this will automatically call [readCache] and [updateCache] with that [Database].
  ///
  /// Internally, this delegates to [execute] in a loop to execute queries.
  Stream<Map> paginate({
    @required String endpoint,
    int batchSize: 100,
    @required String query,
    @required Map variables,
    @required String accessToken,
    Database cache,
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
      );

      yield data;

      for (var item in data.values) {
        if (item is Map && item.containsKey('nextToken')) {
          nextToken = item["nextToken"];
          break;
        }
      }
    } while (nextToken != null);
  }

  /// Execute a GraphQL query without pagination.
  ///
  /// Throws [HttpError] when appropriate.
  ///
  /// If [cache] is passed,
  /// then this will automatically call [readCache] and [updateCache] with that [Database].
  Future<Map> execute({
    @required String endpoint,
    @required String query,
    @required Map variables,
    @required String accessToken,
    Database cache,
  }) async {
    int cacheKey;
    var body = jsonEncode({"query": query, "variables": variables});

    if (cache != null) {
      cacheKey = getCacheKey(endpoint, body);
      var data = await readCache(cache, cacheKey);
      print('$cacheKey ${data != null}');
      if (data != null) {
        return data;
      }
    }

    var response = await http.post(
      endpoint,
      headers: {
        HttpHeaders.authorizationHeader: accessToken,
        HttpHeaders.contentTypeHeader: ContentType.json.mimeType,
      },
      body: body,
    );
    if (response.statusCode != HttpStatus.ok) {
      throw HttpError(response);
    }

    var result = jsonDecode(response.body);
    var data = result["data"];

    if (cacheKey != null) {
      await updateCache(cache, cacheKey, data);
    }

    return data;
  }

  int getCacheKey(String endpoint, String requestBody) {
    return hashValues(endpoint, requestBody);
  }

  final store = StoreRef.main();

  /// Read cache from [db] using [cacheKey].
  Future<Map> readCache(Database db, int cacheKey) async {
    var rec = store.record(cacheKey);
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
      await store.record(cacheKey).put(txn, entry);
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

    return await store.delete(txn, finder: finder);
  }

  /// Get database at `'root/aws_appsync_cache.db'`.
  /// By default, [root] is set to path_provider's [getTemporaryDirectory].
  Future<Database> getCacheDatabase({Directory root}) async {
    root ??= await getTemporaryDirectory();
    return databaseFactoryIo.openDatabase('${root.path}/aws_appync_cache.db');
  }
}

extension StringRepr on String {
  String toRepr() => replaceAll('\n', '\\n');
}

class HttpError implements Exception {
  final http.Response response;

  HttpError(this.response);

  @override
  String toString() {
    var repr = response.body.toRepr();
    return "$runtimeType ${response.statusCode}: '$repr'";
  }
}
