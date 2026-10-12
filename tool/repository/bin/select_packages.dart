import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart';
import 'package:tina_repository_tools/repository.dart';

// These fixtures exercise the executable/UI, not arbitrary owned packages.
// Keep unknown tools conservative; new shared build helpers still run all CI.
const executableSmokeFiles = {
  'tool/smoke_engine2.py',
  'tool/smoke_backend_selection.py',
  'tool/smoke_classification_panel.py',
  'tool/smoke_notcurses_images.py',
  'tool/smoke_notcurses_startup.py',
  'tool/smoke_panel_paint.py',
  'tool/smoke_process_output.py',
  'tool/smoke_restart.py',
  'tool/smoke_resume_terminal.py',
  'tool/smoke_shell.py',
  'tool/ci/run_release_smokes.py',
  'tool/ci/test_release_smokes.py',
  'tool/ci/test_smoke_idle.py',
};

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
  Map<String, Set<String>> dependencies,
) {
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
    if (executableSmokeFiles.contains(file) &&
        directories.containsKey('tina_tui')) {
      selected.add('tina_tui');
      continue;
    }
    if (file.startsWith('.github/') ||
        (file.startsWith('tool/') &&
            !file.startsWith('tool/repository/test/') &&
            file != 'tool/repository/README.md') ||
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

bool needsInteractiveChecks(
  Iterable<String> files,
  Set<String> affected, {
  bool appVersionOnly = false,
}) =>
    affected.contains('tina_tui') ||
    files.any(
      (file) =>
          file.startsWith('apps/tina_cli/') &&
          file != 'apps/tina_cli/lib/version.g.dart' &&
          !(file == 'apps/tina_cli/pubspec.yaml' && appVersionOnly) &&
          affected.contains('tina'),
    );

Future<void> main(List<String> arguments) async {
  final root = await repositoryRoot();
  final policy =
      jsonDecode(
            File('${root.path}/tool/repository/policy.json').readAsStringSync(),
          )
          as Map;
  final directories = (policy['packagePaths'] as Map).cast<String, String>();
  var full = arguments.contains('--full');
  var base = Platform.environment['BASE_SHA'];
  var files = <String>[];
  var appVersionOnly = false;
  const appManifest = 'apps/tina_cli/pubspec.yaml';
  if (!full) {
    if (base == null || base.isEmpty || RegExp(r'^0+$').hasMatch(base)) {
      full = true;
    } else {
      if (Platform.environment['MERGE_BASE'] == 'true') {
        final merge = Process.runSync('git', [
          'merge-base',
          base,
          'HEAD',
        ], workingDirectory: root.path);
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
      ], workingDirectory: root.path);
      if (diff.exitCode != 0) {
        stderr.writeln('Cannot compare base revision; running every package.');
        full = true;
      } else {
        files = (diff.stdout as String)
            .split('\x00')
            .where((s) => s.isNotEmpty)
            .toList();
        if (files.contains(appManifest)) {
          final old = Process.runSync('git', [
            'show',
            '$base:$appManifest',
          ], workingDirectory: root.path);
          appVersionOnly =
              old.exitCode == 0 &&
              versionOnlyManifestChange(
                old.stdout as String,
                File('${root.path}/$appManifest').readAsStringSync(),
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
        );
  final interactive = needsInteractiveChecks(
    files,
    affected,
    appVersionOnly: appVersionOnly,
  );
  // Repository architecture guards check cross-package rules on every code change.
  final selected = {
    ...affected,
    if (affected.isNotEmpty) 'tina_repository_tools',
  }.toList()..sort();
  final outputs =
      'packages=${jsonEncode(selected)}\ninteractive=$interactive\nfull=$full\n';
  stdout.write(outputs);
  final outputFile = Platform.environment['GITHUB_OUTPUT'];
  if (outputFile != null) {
    File(outputFile).writeAsStringSync(outputs, mode: FileMode.append);
  }
}
