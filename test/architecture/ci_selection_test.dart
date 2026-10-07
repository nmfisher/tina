import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../../tool/ci/select_packages.dart';

void main() {
  test(
    'version-only bumps do not force unrelated suites; SDK/dependency changes do',
    () {
      const before =
          'name: tina\nversion: 1.0.0\nenvironment:\n  sdk: ^3.12.0\n';
      expect(
        versionOnlyManifestChange(
          before,
          before.replaceFirst('1.0.0', '1.0.1'),
        ),
        isTrue,
      );
      expect(
        versionOnlyManifestChange(
          before,
          before.replaceFirst('3.12.0', '3.13.0'),
        ),
        isFalse,
      );
      expect(
        versionOnlyManifestChange(
          before,
          '$before\ndependencies:\n  http: any\n',
        ),
        isFalse,
      );
    },
  );
  const directories = {
    'tina': '.',
    'core': 'packages/core',
    'plugin': 'packages/plugin',
    'ui': 'packages/ui',
    'unrelated': 'packages/unrelated',
  };
  final dependencies = {
    'tina': {'ui'},
    'core': <String>{},
    'plugin': {'core'},
    'ui': {'plugin'},
    'unrelated': <String>{},
  };
  test(
    'release bump plus plugin change retains affected consumer coverage',
    () {
      expect(
        selectPackages(
          [
            'pubspec.yaml',
            'lib/version.g.dart',
            'packages/plugin/lib/plugin.dart',
          ],
          directories,
          dependencies,
          rootVersionOnly: true,
        ),
        {'tina', 'plugin', 'ui'},
      );
    },
  );
  test('selects transitive consumers, but not unrelated packages', () {
    expect(
      selectPackages(['packages/core/lib/api.dart'], directories, dependencies),
      {'core', 'plugin', 'ui', 'tina'},
    );
    expect(
      selectPackages(
        ['packages/ui/test/widget_test.dart'],
        directories,
        dependencies,
      ),
      {'ui', 'tina'},
    );
  });
  test('docs skip tests; markdown fixtures still select their owner', () {
    expect(
      selectPackages(
        ['README.md', 'docs/design.md', 'packages/ui/README.md'],
        directories,
        dependencies,
      ),
      isEmpty,
    );
    expect(
      selectPackages(
        [
          'packages/ui/test/fixtures/answer.md',
          'packages/ui/test/fixtures/README.md',
        ],
        directories,
        dependencies,
      ),
      {'ui', 'tina'},
    );
  });
  test('shared config, native submodule and unknown paths run everything', () {
    for (final file in [
      'pubspec.lock',
      'tool/ci/select_packages.dart',
      '.github/workflows/ci.yml',
      'packages/dart_notcurses',
      'packages/new_plugin/lib/plugin.dart',
      '.dockerignore',
    ]) {
      expect(
        selectPackages([file], directories, dependencies),
        directories.keys.toSet(),
        reason: file,
      );
    }
  });
  test('root test changes need root coverage only', () {
    expect(
      selectPackages(['test/version_test.dart'], directories, dependencies),
      {'tina'},
    );
  });
  test('manifest graph includes dev dependencies and overrides', () {
    final root = Directory.systemTemp.createTempSync('tina-ci-graph-');
    addTearDown(() => root.deleteSync(recursive: true));
    File(path.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: example
dependencies:
  core: any
dev_dependencies:
  fixture: any
dependency_overrides:
  override: any
''');
    expect(packageDependencies(root, {'example': '.'}), {
      'example': {'core', 'fixture', 'override'},
    });
  });
  test(
    'every owned CI job is gated by the selector, with full-run escape hatches',
    () async {
      final uri = await Isolate.resolvePackageUri(
        Uri.parse('package:tina/version.g.dart'),
      );
      final root = path.dirname(path.dirname(uri!.toFilePath()));
      final policy =
          jsonDecode(
                File(
                  path.join(root, 'tool/architecture/policy.json'),
                ).readAsStringSync(),
              )
              as Map;
      final ci =
          loadYaml(
                File(
                  path.join(root, '.github/workflows/ci.yml'),
                ).readAsStringSync(),
              )
              as Map;
      final jobs = ci['jobs'] as Map;
      final gated = <String>{};
      for (final job in jobs.values.cast<Map>()) {
        final condition = job['if'];
        if (condition is! String ||
            !condition.contains('fromJSON(needs.changes.outputs.packages)'))
          continue;
        expect(job['needs'], 'changes');
        for (final name in (policy['ownedPackages'] as List).cast<String>()) {
          if (condition.contains("'$name'")) gated.add(name);
        }
      }
      expect(gated, (policy['ownedPackages'] as List).toSet());
      final triggers = ci['on'] as Map;
      expect(triggers.containsKey('schedule'), isTrue);
      expect(triggers.containsKey('workflow_dispatch'), isTrue);
      expect((jobs['changes'] as Map)['outputs'], contains('packages'));
    },
  );
}
