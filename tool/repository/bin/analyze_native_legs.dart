/// Second analyze pass with the native/io legs of conditional seams
/// forced.
///
/// Dart 3.13's analyzer no longer selects the `if (dart.library.io)` leg
/// during plain `dart analyze` (no CLI flag, options key, or pubspec
/// stanza changes this), so the native legs of every conditional barrel
/// go unanalyzed against their consumers — rot there is invisible. The
/// pass is temporary-by-construction: it rewrites each
/// `if (dart.library.io)` directive condition to `if (dart.library.core)`
/// (valid config syntax, always true — `if (true)` is not), runs
/// `dart analyze`, and restores every file in a finally block. Nothing
/// is committed; the wasm compilation is untouched.
///
/// Usage: dart run bin/analyze_native_legs.dart <package-dir>
library;

import 'dart:io';

final _condition = RegExp(r'if \(dart\.library\.io\)');

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart run bin/analyze_native_legs.dart <pkg>');
    exit(64);
  }
  final dir = Directory(Directory(args.single).resolveSymbolicLinksSync());
  if (!File('${dir.path}/pubspec.yaml').existsSync()) {
    stderr.writeln('no pubspec.yaml in $dir');
    exit(64);
  }
  final patched = <File, String>{};
  stdout.writeln('analyze (native legs): $dir');
  var result = 1;
  try {
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.contains('.dart_tool')) continue;
      final original = entity.readAsStringSync();
      // The token only ever appears as an import/export directive
      // condition (single- or multi-line), never inside strings.
      final forced =
          original.replaceAllMapped(_condition, (m) => 'if (dart.library.core)');
      if (forced != original) {
        patched[entity] = original;
        entity.writeAsStringSync(forced);
        stdout.writeln('  forced io leg: ${entity.path}');
      }
    }
    if (patched.isEmpty) {
      stdout.writeln('  (no conditional io barrels in this package)');
      exit(0);
    }
    final analysis =
        Process.runSync(Platform.resolvedExecutable, ['analyze', dir.path]);
    stdout.write(analysis.stdout);
    stderr.write(analysis.stderr);
    result = analysis.exitCode;
  } finally {
    patched.forEach((file, original) => file.writeAsStringSync(original));
  }
  exit(result);
}
