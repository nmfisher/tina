import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A real source tree whose shape belongs to the tests, independent of Tina's
/// package layout. Each caller gets isolated files and automatic cleanup.
Directory createIndexProject({Map<String, String> extraFiles = const {}}) {
  final root = Directory.systemTemp.createTempSync('index_fixture_');
  addTearDown(() => root.deleteSync(recursive: true));
  final files = <String, String>{
    'pubspec.yaml': 'name: fixture\n',
    'lib/base.dart': 'abstract class Base { void execute(); }\n',
    'lib/first.dart': '''
import 'base.dart';
class First extends Base {
  void execute() {}
}
''',
    'lib/second.dart': '''
import 'package:fixture/base.dart';
class Second extends Base {
  void execute() {}
}
''',
    'lib/controller.dart': '''
import 'dart:async';
import 'package:external/external.dart';
import 'first.dart';
class Controller {
  void run() {}
}
''',
    ...extraFiles,
  };
  for (final entry in files.entries) {
    File(p.join(root.path, entry.key))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(entry.value);
  }
  return root;
}
