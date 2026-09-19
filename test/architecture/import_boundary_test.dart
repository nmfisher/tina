import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../tool/architecture/policy.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

Future<void> main() async {
  test(
    'owned sources and manifests obey architecture policy and exact baseline',
    () async {
      // Other suites change cwd; package resolution is independent of that state.
      final uri = await Isolate.resolvePackageUri(
        Uri.parse('package:tina/config/runtime_config.dart'),
      );
      final root = p.dirname(p.dirname(p.dirname(uri!.toFilePath())));
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
  final runtimeUri = (await Isolate.resolvePackageUri(
    Uri.parse('package:tina/config/user_config.dart'),
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

/// Residual root-side boundary check (A06): the TOML user-config loader stays
/// in the root package beside the CLI, and its own closure must stay free of
/// terminal packages. The application closure itself is guarded by
/// packages/tina_app/test/config/runtime_boundary_test.dart and by the A07
/// graph checker (tool/architecture).
