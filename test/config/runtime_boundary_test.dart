import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<void> main() async {
  // Other integration tests change process cwd; resolve through the package map.
  final runtimeUri = (await Isolate.resolvePackageUri(
    Uri.parse('package:tina/config/runtime_config.dart'),
  ))!;
  final repository = runtimeUri.resolve('../../');
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

  for (final source in [
    'lib/config/runtime_config.dart',
    'lib/application/conversation_operations.dart',
    'lib/application/turn_executor.dart',
    'lib/application/background_job_supervisor.dart',
    'lib/config/resume_request.dart',
    'lib/composition/provider_resolution.dart',
    'lib/composition/app_composition.dart',
    'lib/composition/agent_composition.dart',
    'lib/summaries/summary_runner.dart',
    'lib/environment/environment_runner.dart',
    'lib/persistence/session_restore.dart',
  ]) {
    test('$source has no transitive parser or terminal dependency', () {
      expect(
        violations(source, {
          'args',
          'toml',
          'tina_console',
          'dart_notcurses',
          'lib/config.dart',
          'lib/config/user_config.dart',
        }),
        isEmpty,
      );
    });
  }
  for (final source in [
    'lib/summaries/summary_index.dart',
    'lib/summaries/summary_runner.dart',
    'lib/environment/environment_index.dart',
    'lib/environment/environment_runner.dart',
  ]) {
    test('$source cannot construct application or execution composition', () {
      expect(
        violations(source, {
          'lib/composition/app_composition.dart',
          'lib/composition/execution_runtime.dart',
          'lib/composition/project_services.dart',
        }),
        isEmpty,
      );
    });
  }
  for (final source in [
    'lib/summaries/summary_index.dart',
    'lib/summaries/summary_repository.dart',
    'lib/environment/environment_index.dart',
    'lib/environment/environment_repository.dart',
    'lib/environment/environment_runner.dart',
    'lib/summaries/summary_runner.dart',
  ]) {
    test('$source does not perform filesystem or process IO', () {
      final content = File.fromUri(
        repository.resolve(source),
      ).readAsStringSync();
      final unit = parseString(content: content).unit;
      final imports = unit.directives.whereType<UriBasedDirective>().map(
        (d) => d.uri.stringValue,
      );
      expect(imports, isNot(contains('dart:io')));
    });
  }
  test('summary planning has no transitive filesystem dependency', () {
    expect(
      violations('lib/summaries/summary_repository.dart', {'dart:io'}),
      isEmpty,
    );
  });
  test('engine Agent has no host presentation dependency', () {
    final agent = repository.resolve(
      'packages/tina_engine/lib/src/agent/agent.dart',
    );
    final unit = parseString(
      content: File.fromUri(agent).readAsStringSync(),
    ).unit;
    expect(
      unit.directives.whereType<UriBasedDirective>().map(
        (d) => d.uri.stringValue,
      ),
      isNot(contains('../host/host_interface.dart')),
    );
  });
  test('persisted configuration has no transitive terminal dependency', () {
    expect(
      violations('lib/config/user_config.dart', {
        'tina_console',
        'dart_notcurses',
      }),
      isEmpty,
    );
  });
}
