import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart';

/// Include test dependencies: a fixture/API change can break a consumer's tests
/// even when it is not one of that consumer's runtime dependencies.
Map<String, Set<String>> packageDependencies(
  Directory root,
  Map<String, String> directories,
) {
  final result = <String, Set<String>>{};
  for (final entry in directories.entries) {
    final manifest =
        loadYaml(
              File(
                path.join(root.path, entry.value, 'pubspec.yaml'),
              ).readAsStringSync(),
            )
            as Map;
    result[entry.key] = {
      for (final section in [
        'dependencies',
        'dev_dependencies',
        'dependency_overrides',
      ])
        ...(manifest[section] as Map? ?? {}).keys.cast<String>(),
    };
  }
  return result;
}

Set<String> selectPackages(
  Iterable<String> files,
  Map<String, String> directories,
  Map<String, Set<String>> dependencies, {
  bool rootVersionOnly = false,
}) {
  final selected = <String>{};
  for (final file in files) {
    // Only known documentation paths. Markdown under lib/test may be a prompt
    // or rendering fixture and must select its owning package.
    const docNames = [
      'README.md',
      'AGENTS.md',
      'CHANGELOG.md',
      'ARCHITECTURE.md',
    ];
    if (file.startsWith('docs/') ||
        file == '.github/CI.md' ||
        docNames.contains(file) ||
        directories.values
            .where((d) => d != '.')
            .any(
              (d) =>
                  file.startsWith('$d/docs/') ||
                  docNames.any((name) => file == '$d/$name'),
            )) {
      continue;
    }
    if (file == 'pubspec.yaml' && rootVersionOnly) {
      selected.add('tina');
      continue;
    }
    if (file.startsWith('.github/') ||
        file.startsWith('tool/') ||
        file == 'pubspec.yaml' ||
        file == 'pubspec.lock' ||
        file == 'analysis_options.yaml' ||
        file == 'dart_test.yaml' ||
        file == '.gitmodules' ||
        file.startsWith('packages/dart_notcurses')) {
      return directories.keys.toSet();
    }
    final owner = directories.entries
        .where(
          (entry) =>
              entry.value != '.' &&
              (file == entry.value || file.startsWith('${entry.value}/')),
        )
        .firstOrNull;
    if (owner != null) {
      selected.add(owner.key);
    } else if (file.startsWith('lib/') ||
        file.startsWith('bin/') ||
        file.startsWith('test/')) {
      selected.add('tina');
    } else {
      // New/deleted packages, build configuration and unknown paths must never
      // silently evade CI. Prefer too much coverage to an incomplete graph.
      return directories.keys.toSet();
    }
  }
  var changed = true;
  while (changed) {
    changed = false;
    for (final entry in dependencies.entries) {
      if (!selected.contains(entry.key) && entry.value.any(selected.contains)) {
        selected.add(entry.key);
        changed = true;
      }
    }
  }
  return selected;
}

bool versionOnlyManifestChange(String before, String after) {
  final oldManifest = Map<String, dynamic>.from(loadYaml(before) as Map)
    ..remove('version');
  final newManifest = Map<String, dynamic>.from(loadYaml(after) as Map)
    ..remove('version');
  return jsonEncode(oldManifest) == jsonEncode(newManifest);
}

void main(List<String> arguments) {
  final root = Directory.current;
  final policy =
      jsonDecode(File('tool/architecture/policy.json').readAsStringSync())
          as Map;
  final directories = (policy['packagePaths'] as Map).cast<String, String>();
  var full = arguments.contains('--full');
  var base = Platform.environment['BASE_SHA'];
  var files = <String>[];
  var rootVersionOnly = false;
  if (!full) {
    if (base == null || base.isEmpty || RegExp(r'^0+$').hasMatch(base)) {
      full = true;
    } else {
      if (Platform.environment['MERGE_BASE'] == 'true') {
        final merge = Process.runSync('git', ['merge-base', base, 'HEAD']);
        if (merge.exitCode == 0) base = (merge.stdout as String).trim();
        // If unavailable, the direct diff is conservative (it may include
        // unrelated base-branch changes), rather than omitting coverage.
      }
      // --no-renames includes both old and new locations when a file moves.
      final diff = Process.runSync('git', [
        'diff',
        '--name-only',
        '--no-renames',
        '-z',
        base,
        'HEAD',
      ]);
      if (diff.exitCode != 0) {
        stderr.writeln('Cannot compare base revision; running every package.');
        full = true;
      } else {
        files = (diff.stdout as String)
            .split('\x00')
            .where((s) => s.isNotEmpty)
            .toList();
        if (files.contains('pubspec.yaml')) {
          final old = Process.runSync('git', ['show', '$base:pubspec.yaml']);
          rootVersionOnly =
              old.exitCode == 0 &&
              versionOnlyManifestChange(
                old.stdout as String,
                File('pubspec.yaml').readAsStringSync(),
              );
        }
      }
    }
  }
  final affected = full
      ? directories.keys.toSet()
      : selectPackages(
          files,
          directories,
          packageDependencies(root, directories),
          rootVersionOnly: rootVersionOnly,
        );
  final interactive =
      affected.contains('tina_tui') ||
      files.any(
        (f) =>
            f.startsWith('bin/') ||
            (f.startsWith('lib/') && f != 'lib/version.g.dart'),
      );
  // The root analyzer and architecture guards also check cross-package rules.
  final selected = {...affected, if (affected.isNotEmpty) 'tina'}.toList()
    ..sort();
  final outputs =
      'packages=${jsonEncode(selected)}\ninteractive=$interactive\nfull=$full\n';
  stdout.write(outputs);
  final outputFile = Platform.environment['GITHUB_OUTPUT'];
  if (outputFile != null) {
    File(outputFile).writeAsStringSync(outputs, mode: FileMode.append);
  }
}
