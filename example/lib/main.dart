import 'dart:async';
import 'dart:convert';

import 'package:aws_appsync/aws_appsync.dart';
import 'package:flutter/material.dart';
import 'package:flutter_json_widget/flutter_json_widget.dart';

import 'progress_mixin.dart';

void main() => runApp(MyApp());

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        fontFamily: 'Courier',
      ),
      home: MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage>
    with ProgressMixin<MyHomePage> {
  final endpoint = TextEditingController();
  final query = TextEditingController();
  final variables = TextEditingController(text: '{}');
  final accessToken = TextEditingController();

  var results;
  Duration timeTaken;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('AWS AppSync example'),
      ),
      body: SafeArea(
        child: Stack(
          children: <Widget>[
            ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                TextField(
                  controller: endpoint,
                  decoration: InputDecoration(
                    labelText: 'endpoint',
                  ),
                ),
                TextField(
                  controller: query,
                  decoration: InputDecoration(
                    labelText: 'query',
                  ),
                  maxLines: null,
                ),
                TextField(
                  controller: variables,
                  decoration: InputDecoration(
                    labelText: 'variables',
                  ),
                  maxLines: null,
                ),
                TextField(
                  controller: accessToken,
                  decoration: InputDecoration(
                    labelText: 'accessToken',
                    hintText: 'You can copy this from flutter_cognito_plugin',
                  ),
                ),
                Divider(),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 16,
                  children: <Widget>[
                    RaisedButton(
                      child: Text('execute'),
                      onPressed: createOnPressed(execute),
                    ),
                    RaisedButton(
                      child: Text('execute (cache enabled)'),
                      onPressed: createOnPressed(executeWithCache),
                    ),
                    RaisedButton(
                      child: Text('paginate'),
                      onPressed: createOnPressed(paginate),
                    ),
                    RaisedButton(
                      child: Text('paginate (cache enabled)'),
                      onPressed: createOnPressed(paginateWithCache),
                    ),
                  ],
                ),
                Divider(),
                Center(
                    child: Text(
                  'Results',
                  style: Theme.of(context).textTheme.title,
                )),
                if (timeTaken != null) Center(child: Text('(took $timeTaken)')),
                if (results is Map)
                  JsonViewerWidget(results)
                else if (results is List)
                  for (var result in results) JsonViewerWidget(result)
                else
                  Text("$results"),
              ],
            ),
            buildProgressStackWidget(),
          ],
        ),
      ),
    );
  }

  final appSync = AppSync();

  Future<dynamic> execute() async {
    return await appSync.execute(
      endpoint: endpoint.text.trim(),
      query: query.text,
      variables: jsonDecode(variables.text.trim()),
      accessToken: accessToken.text,
    );
  }

  Future<dynamic> executeWithCache() async {
    return await appSync.execute(
      endpoint: endpoint.text.trim(),
      query: query.text,
      variables: jsonDecode(variables.text.trim()),
      accessToken: accessToken.text,
      cache: await appSync.getCacheDatabase(),
    );
  }

  Future<dynamic> paginate() async {
    return appSync.paginate(
      endpoint: endpoint.text.trim(),
      query: query.text,
      variables: jsonDecode(variables.text.trim()),
      accessToken: accessToken.text,
    );
  }

  Future<dynamic> paginateWithCache() async {
    return appSync.paginate(
      endpoint: endpoint.text.trim(),
      query: query.text,
      variables: jsonDecode(variables.text.trim()),
      accessToken: accessToken.text,
      cache: await appSync.getCacheDatabase(),
      batchSize: 500,
    );
  }

  ProgressMixinTaskWrapper createOnPressed(ProgressMixinTask fn) {
    return wrapTask(() async {
      var s = DateTime.now();
      setState(() {
        timeTaken = null;
      });

      try {
        var data = await fn();
        if (data is Stream) {
          results = [];
          await for (var page in data) {
            if (!mounted) return;
            setState(() {
              results.add(page);
            });
          }
        } else {
          setState(() {
            results = data;
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            results = e;
          });
        }
      }

      setState(() {
        var e = DateTime.now();
        timeTaken = e.difference(s);
      });
    });
  }
}
