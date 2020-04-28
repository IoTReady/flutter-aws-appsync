import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';

typedef FutureOr<T> ProgressMixinTask<T>();
typedef Future<T> ProgressMixinTaskWrapper<T>();

/// Contains utilities for widgets that need to display progress indicators
/// while they perform background task(s).
mixin ProgressMixin<T extends StatefulWidget> implements State<T> {
  /// - A value of [-1] implies no backgound task.
  ///
  /// - A value of [null] implies a background task is running,
  ///   but whose progress can't be determined.
  ///
  /// - Any other value is the progress of the current background task,
  ///   on a scale of [0.0] to [1.0].
  double progress = -1;

  /// Is the widget currently doing any background work?
  bool get isDoingWork {
    if (progress == null) {
      return true;
    } else {
      return progress >= 0;
    }
  }

  /// Set whether widget is doing any background work.
  /// Don't forget to wrap this in a [setState()] call.
  set isDoingWork(bool value) {
    if (value) {
      progress = null;
    } else {
      progress = -1;
    }
  }

  /// Same as [buildProgressWidget], but intended to be placed inside a [Stack].
  Widget buildProgressStackWidget({
    MainAxisAlignment mainAxisAlignment = MainAxisAlignment.end,
  }) {
    return Column(
      mainAxisAlignment: mainAxisAlignment,
      children: <Widget>[
        Center(
          child: buildProgressWidget(),
        ),
      ],
    );
  }

  /// Returns a [Widget] that visualizes the progress of current backgound task.
  Widget buildProgressWidget({Widget idle}) {
    if (!isDoingWork) {
      return Container();
    }
    return LinearProgressIndicator(value: null);
  }

  /// Returns a modified [fn], that will:
  /// - Automatically set [progress] to [null] when it is invoked; and
  /// - Set [progress] to [-1], before returning.
  /// - Return [Future<T>], even if the original return type was [T].
  ProgressMixinTaskWrapper<T> wrapTask<T>(ProgressMixinTask<T> fn) {
    if (isDoingWork) {
      return null;
    }
    return () async {
      if (mounted) {
        setState(() {
          progress = null;
        });
        try {
          return await fn();
        } finally {
          if (mounted) {
            setState(() {
              progress = -1;
            });
          }
        }
      }
      return null;
    };
  }
}
