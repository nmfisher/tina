import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

/// Guards the pubspec ↔ generated-version-constant contract: a version bump
/// without `dart run apps/tina_cli/tool/generate_version.dart` fails here (and CI) instead
/// of shipping a binary that reports the wrong version — and never sees an
/// update, since `/update` compares against this constant.
Future<void> main() async {
  test('lib/version.g.dart matches pubspec.yaml version', () async {
    // Other suites can change cwd and
    // `dart test` runs files concurrently in one process, so a relative path
    // here would be resolved against whatever directory happens to be current
    // at that instant — a race that fails as `Cannot open file, path =
    // 'pubspec.yaml'`. Package resolution is independent of cwd, so anchor the
    // application root off package:tina instead.
    final generatedUri = await Isolate.resolvePackageUri(
      Uri.parse('package:tina/version.g.dart'),
    );
    final generatedPath = generatedUri!.toFilePath();
    final pubspec = File.fromUri(
      generatedUri.resolve('../pubspec.yaml'),
    ).readAsStringSync();
    final pub = RegExp(
      r'^version:\s*(\S+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec)?.group(1);
    expect(pub, isNotNull, reason: 'pubspec.yaml has no version: line');

    final generated = File(generatedPath).readAsStringSync();
    final gen = RegExp(
      r"tinaVersion = '([^']+)'",
    ).firstMatch(generated)?.group(1);
    expect(
      gen,
      equals(pub),
      reason:
          'lib/version.g.dart is stale — run '
          '`dart run apps/tina_cli/tool/generate_version.dart` from the repository root and commit the result.',
    );
  });
}
