import 'dart:convert';
import 'dart:io';
import 'package:tina_repository_tools/repository.dart';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:tina_repository_tools/src/architecture/policy.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

Future<void> main() async {
  final repository = (await repositoryRoot()).uri;
  test(
    'owned sources and manifests obey architecture policy and exact baseline',
    () async {
      final root = repository.toFilePath();
      final policy = ArchitecturePolicy.read(
        p.join(root, 'tool/repository/policy.json'),
      );
      final result = checkWorkspace(root, policy);
      final baseline =
          jsonDecode(
                File(
                  p.join(
                    root,
                    'tool/repository',
                    policy.data['baseline'] as String,
                  ),
                ).readAsStringSync(),
              )
              as List;
      expect(applyBaseline(result.violations, baseline), isEmpty);
      expect(result.files, greaterThan(0));
    },
  );
  final configFile = repository.resolve(
    'apps/tina_cli/.dart_tool/package_config.json',
  );
  final config = jsonDecode(File.fromUri(configFile).readAsStringSync()) as Map;
  final packages = <String, Uri>{
    for (final entry in config['packages'] as List)
      entry['name'] as String: Directory.fromUri(
        configFile.resolve(entry['rootUri'] as String),
      ).uri.resolve(entry['packageUri'] as String? ?? ''),
  };

  List<String> violations(String start, Set<String> forbidden) {
    final seen = <Uri>{};
    final failures = <String>[];
    void visit(Uri uri, List<String> chain) {
      if (!seen.add(uri)) return;
      final relative = p.relative(
        File.fromUri(uri).path,
        from: repository.toFilePath(),
      );
      if (forbidden.contains(relative)) {
        failures.add([...chain, relative].join(' -> '));
        return;
      }
      final unit = parseString(
        content: File.fromUri(uri).readAsStringSync(),
        path: uri.toFilePath(),
        throwIfDiagnostics: false,
      ).unit;
      for (final directive in unit.directives) {
        if (directive is! UriBasedDirective) continue;
        final targets = <String?>[directive.uri.stringValue];
        if (directive is NamespaceDirective) {
          targets.addAll(
            directive.configurations.map((c) => c.uri.stringValue),
          );
        }
        for (final target in targets.whereType<String>()) {
          final next = Uri.parse(target);
          if (next.scheme == 'dart') {
            if (forbidden.contains(target))
              failures.add([...chain, relative, target].join(' -> '));
            continue;
          }
          if (next.scheme == 'package') {
            final name = next.pathSegments.first;
            if (forbidden.contains(name)) {
              failures.add([...chain, relative, target].join(' -> '));
              continue;
            }
            final root = packages[name];
            if (root == null) throw StateError('Unresolved package $name');
            visit(root.resolve(next.pathSegments.skip(1).join('/')), [
              ...chain,
              relative,
            ]);
          } else {
            visit(uri.resolveUri(next), [...chain, relative]);
          }
        }
      }
    }

    visit(repository.resolve(start), []);
    return failures;
  }

  test(
    'CLI executable cannot reach legacy app, workflow or repository indexing',
    () {
      expect(
        violations('apps/tina_cli/bin/tina.dart', {
          'tina_app',
          'tina_engine',
          'attractor',
          'packages/classification/lib/exploration.dart',
          'packages/classification/lib/src/exploration/exploration_workflow.dart',
          'tina_index',
          'tina_workflows',
        }),
        isEmpty,
      );
      expect(
        File.fromUri(repository.resolve('pubspec.yaml')).existsSync(),
        isFalse,
      );
    },
  );
  test('configuration reader has no transitive terminal dependency', () {
    expect(
      violations('apps/tina_cli/lib/src/config_document.dart', {
        'tina_console',
        'dart_notcurses',
      }),
      isEmpty,
    );
  });
  test(
    'chat rendering and connection adapter cannot reach the runtime chat plugin',
    () {
      for (final source in [
        'packages/plugins/tina_chat_tui/lib/src/chat_tui.dart',
        'packages/plugins/tina_chat_tui/lib/src/connection_chat.dart',
      ]) {
        expect(
          violations(source, {
            'packages/plugins/tina_chat/lib/tina_chat.dart',
            'apps/tina_cli/lib/src/assembly.dart',
          }),
          isEmpty,
        );
      }
    },
  );
  test('activity browser cannot reach runtime activity, chat or assembly', () {
    expect(
      violations(
        'packages/plugins/tina_activity_tui/lib/tina_activity_tui.dart',
        {
          'packages/plugins/tina_activity/lib/tina_activity.dart',
          'packages/plugins/tina_chat/lib/tina_chat.dart',
          'apps/tina_cli/lib/src/assembly.dart',
        },
      ),
      isEmpty,
    );
  });
  test('session composition has no transitive frontend dependency', () {
    expect(
      violations('apps/tina_cli/lib/session.dart', {
        'tina_tui',
        'tina_console',
        'dart_notcurses',
        'tina_chat_tui',
        'tina_activity_tui',
        'tina_context_tui',
        'tina_cwd_tui',
        'tina_approvals_tui',
        'tina_plans_tui',
        'tina_classification_tui',
        'tina_mcp_tui',
      }),
      isEmpty,
    );
  });
  test('reusable TUI cannot reach application or concrete feature owners', () {
    expect(
      violations('packages/tina_tui/lib/tina_tui.dart', {
        'tina',
        'tina_tools',
        'tina_llm',
        'tina_persistence',
        'tina_chat',
        'tina_plans',
        'tina_approvals',
        'tina_mcp',
      }),
      isEmpty,
    );
  });
  test('process launcher fixture keeps the TUI out of child startup', () {
    expect(
      violations('apps/tina_cli/test/fixtures/process_launcher.dart', {
        'tina_tui',
        'tina_console',
        'dart_notcurses',
      }),
      isEmpty,
      reason: 'Each spawned JIT command must avoid compiling the full TUI.',
    );
  });
  test('runtime feature construction cannot import a presentation package', () {
    expect(
      violations('apps/tina_cli/lib/src/plugin_catalog.dart', {
        'tina_console',
        'dart_notcurses',
        'tina_chat_tui',
        'tina_activity_tui',
        'tina_context_tui',
        'tina_cwd_tui',
        'tina_approvals_tui',
        'tina_plans_tui',
        'tina_classification_tui',
        'tina_mcp_tui',
      }),
      isEmpty,
    );
  });
  test(
    'session view cannot reach application assembly or concrete runtime services',
    () {
      expect(
        violations('packages/tina_tui/lib/src/session_view.dart', {
          'apps/tina_cli/lib/src/assembly.dart',
          'apps/tina_cli/lib/src/tui_session.dart',
          'apps/tina_cli/lib/src/tui_presentation.dart',
          'packages/tina_tui/lib/src/settings_panel.dart',
          'tina_tools',
          'tina_persistence',
          'tina_llm',
        }),
        isEmpty,
      );
    },
  );
  test(
    'settings dialogs cannot reach configuration owners or runtime services',
    () {
      for (final entry in ['settings_panel.dart', 'providers_panel.dart']) {
        expect(
          violations('packages/tina_tui/lib/src/$entry', {
            'apps/tina_cli/lib/src/assembly.dart',
            'apps/tina_cli/lib/src/assembly_config.dart',
            'apps/tina_cli/lib/src/config_document.dart',
            'apps/tina_cli/lib/src/scoped_config.dart',
            'apps/tina_cli/lib/src/config_settings_management.dart',
            'apps/tina_cli/lib/src/plugin_settings.dart',
            'tina_host',
            'tina_tools',
            'tina_llm',
            'tina_persistence',
          }),
          isEmpty,
          reason: entry,
        );
      }
    },
  );
}
