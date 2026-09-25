import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Guards the pubspec ↔ generated-version-constant contract: a version bump
/// without `dart run tool/generate_version.dart` fails here (and CI) instead
/// of shipping a binary that reports the wrong version — and never sees an
/// update, since `/update` compares against this constant.
Future<void> main() async {
  test('lib/version.g.dart matches pubspec.yaml version', () async {
    // Other suites change cwd (resolve_session_test, tui_coordinator_test) and
    // `dart test` runs files concurrently in one process, so a relative path
    // here would be resolved against whatever directory happens to be current
    // at that instant — a race that fails as `Cannot open file, path =
    // 'pubspec.yaml'`. Package resolution is independent of cwd, so anchor the
    // repo root off package:tina instead (same pattern as
    // test/architecture/ci_owned_packages_guard_test.dart):
    // <root>/lib/version.g.dart -> strip lib/ -> repo root.
    final generatedUri = await Isolate.resolvePackageUri(
      Uri.parse('package:tina/version.g.dart'),
    );
    final generatedPath = generatedUri!.toFilePath();
    final root = p.dirname(p.dirname(generatedPath));

    final pubspec = File(p.join(root, 'pubspec.yaml')).readAsStringSync();
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
          '`dart run tool/generate_version.dart` and commit the result.',
    );
  });
}
