import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../tool/architecture/policy.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

Future<void> main() async {
  // Resolve from the one retained root library; this is independent of cwd.
  final versionUri = (await Isolate.resolvePackageUri(
    Uri.parse('package:tina/version.g.dart'),
  ))!;
  final repository = versionUri.resolve('../');
  test(
    'owned sources and manifests obey architecture policy and exact baseline',
    () async {
      final root = repository.toFilePath();
      final policy = ArchitecturePolicy.read(
        p.join(root, 'tool/architecture/policy.json'),
      );
      final result = checkWorkspace(root, policy);
      final baseline =
          jsonDecode(
                File(
                  p.join(
                    root,
                    'tool/architecture',
                    policy.data['baseline'] as String,
                  ),
                ).readAsStringSync(),
              )
              as List;
      expect(applyBaseline(result.violations, baseline), isEmpty);
      expect(result.files, greaterThan(0));
    },
  );
  final configFile = repository.resolve('.dart_tool/package_config.json');
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
    'root executable cannot reach legacy app, workflow or repository indexing',
    () {
      expect(
        violations('bin/tina.dart', {
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
      final manifest = File.fromUri(
        repository.resolve('pubspec.yaml'),
      ).readAsStringSync();
      final runtime = manifest
          .split('\ndependencies:')
          .last
          .split('\ndev_dependencies:')
          .first;
      expect(
        RegExp(
          r'^  [a-z_]+:',
          multiLine: true,
        ).allMatches(runtime).map((m) => m.group(0)),
        ['  tina_tui:'],
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
}
