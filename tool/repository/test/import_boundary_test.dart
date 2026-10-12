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
      violations('packages/tina_tui/lib/src/config_document.dart', {
        'tina_console',
        'dart_notcurses',
      }),
      isEmpty,
    );
  });
  test('runtime feature construction cannot import a presentation package', () {
    expect(
      violations('packages/tina_tui/lib/src/plugin_catalog.dart', {
        'tina_console',
        'dart_notcurses',
        'tina_chat_tui',
        'tina_activity_tui',
        'tina_context_tui',
        'tina_approvals_tui',
        'tina_plans_tui',
        'tina_classification_tui',
        'tina_mcp_tui',
      }),
      isEmpty,
    );
  });
}
