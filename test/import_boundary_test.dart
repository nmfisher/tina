import 'dart:io';

import 'package:test/test.dart';

/// The terminal frontend packages. None of the UI-agnostic core layers below
/// may reach into these — the TUI is a swappable frontend, and the agent/LLM/
/// session machinery must compile and run without it (the headless path proves
/// this). `fuzzy_ranker` is the neutral seam the TUI and app providers
/// share; it is allowed everywhere.
const _tuiPackages = <String>['tina_console', 'dart_notcurses'];

/// Core layers guarded against TUI imports. Directories are scanned
/// recursively; bare paths are individual files. Add new core directories
/// here as they are introduced — this is the boundary contract.
const _guarded = <String>[
  // Engine core subsystems (moved into the tina_engine package). These stay
  // UI-agnostic — the engine must compile and run without the TUI packages.
  'packages/tina_engine/lib/src/agent',
  'packages/tina_engine/lib/src/llm',
  'packages/tina_engine/lib/src/tools',
  'packages/tina_engine/lib/src/permissions',
  'packages/tina_engine/lib/src/persistence',
  'packages/tina_engine/lib/src/host',
  'packages/tina_engine/lib/src/platform/paths.dart',
  // Shell core subsystems.
  'lib/completion',
  // The UI-agnostic session/host machinery.
  'lib/conversation.dart',
  'lib/session.dart',
  'lib/session_manager.dart',
  'lib/session_controller.dart',
  'lib/persistence/session_restore.dart',
];

/// Test directories that legitimately exercise the frontend and may import the
/// TUI packages. Everything else under `test/` is a core test and must stay
/// frontend-free (using FakeHostInterface/FakeAgentSink instead of real
/// widgets), so a core test can't accidentally grow a terminal dependency.
const _frontendTestDirs = <String>['test/host', 'test/tui'];

/// Test files outside [_frontendTestDirs] that legitimately need the frontend
/// packages anyway. The boundary only scans *_test.dart files (see below), so
/// this list only needs entries that are themselves *_test.dart. Keep it short —
/// every entry is a deliberate, documented exception, not a pattern to copy.
const _allowlistedFrontendTests = <String>[
  // Config / UserConfig carry a Theme (from tina_console) for terminal
  // color overrides. Tests that assert theme flow through the config layer
  // must construct Theme instances, so they need the package.
  'test/config_test.dart',
  'test/config/user_config_test.dart',
];

void main() {
  test('core layers do not import or export the TUI packages', () {
    final offenders = <String>[];
    for (final entry in _guarded) {
      for (final file in _dartFiles(entry)) {
        final lines = File(file).readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final trimmed = lines[i].trim();
          if (!trimmed.startsWith('import ') && !trimmed.startsWith('export ')) {
            continue;
          }
          if (_tuiPackages.any((p) => trimmed.contains('package:$p/'))) {
            offenders.add('${_rel(file)}:${i + 1}: $trimmed');
          }
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'core layers must not depend on the TUI packages '
          '(${_tuiPackages.join(', ')}); found:\n  ${offenders.join('\n  ')}',
    );
  });

  test('tests outside the frontend dirs do not import the TUI packages', () {
    final offenders = <String>[];
    for (final file in _dartFiles('test')) {
      final rel = _rel(file);
      if (_frontendTestDirs
          .any((d) => rel == d || rel.startsWith('$d/'))) continue;
      if (_allowlistedFrontendTests.contains(rel)) continue;
      // The contract is about core *tests*: `dart test` only runs *_test.dart
      // files, so standalone dev scripts and helpers (run via `dart run`, e.g.
      // the notcurses key probes) are out of scope and would otherwise each
      // need an individual allowlisting. Policing exactly the test files keeps
      // the boundary aligned with what actually runs headless.
      if (!rel.endsWith('_test.dart')) continue;
      final lines = File(file).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final trimmed = lines[i].trim();
        if (!trimmed.startsWith('import ') && !trimmed.startsWith('export ')) {
          continue;
        }
        if (_tuiPackages.any((p) => trimmed.contains('package:$p/'))) {
          offenders.add('$rel:${i + 1}: $trimmed');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'core tests (outside ${_frontendTestDirs.join(', ')}) must not '
          'depend on the TUI packages; use FakeHostInterface/FakeAgentSink '
          'instead. Found:\n  ${offenders.join('\n  ')}',
    );
  });
}

/// All `.dart` files under [path] if it is a directory, or just [path] if it
/// is a file. Missing paths yield an empty list (and fail loudly in the test
/// only if a guarded path silently disappears — see the existence check below).
List<String> _dartFiles(String path) {
  final type = FileSystemEntity.typeSync(path);
  if (type == FileSystemEntityType.file) return [path];
  if (type == FileSystemEntityType.directory) {
    return Directory(path)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .map((f) => f.path)
        .toList();
  }
  // A guarded path that no longer exists is itself a boundary regression —
  // the test would silently pass while scanning nothing.
  throw StateError('guarded import-boundary path does not exist: $path');
}

String _rel(String file) =>
    file.startsWith('${Directory.current.path}/') ? file.substring(Directory.current.path.length + 1) : file;
