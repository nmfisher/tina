import 'dart:io';

import 'package:test/test.dart';

/// Guards the pubspec ↔ generated-version-constant contract: a version bump
/// without `dart run tool/generate_version.dart` fails here (and CI) instead
/// of shipping a binary that reports the wrong version — and never sees an
/// update, since `/update` compares against this constant.
void main() {
  test('lib/version.g.dart matches pubspec.yaml version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final pub = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true)
        .firstMatch(pubspec)
        ?.group(1);
    expect(pub, isNotNull, reason: 'pubspec.yaml has no version: line');

    final generated = File('lib/version.g.dart').readAsStringSync();
    final gen = RegExp(r"tinaVersion = '([^']+)'").firstMatch(generated)?.group(1);
    expect(gen, equals(pub),
        reason: 'lib/version.g.dart is stale — run '
            '`dart run tool/generate_version.dart` and commit the result.');
  });
}
