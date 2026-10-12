import 'dart:convert';
import 'dart:io';
import 'package:tina_repository_tools/repository.dart';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../bin/select_packages.dart';

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
    'tina_repository_tools': 'tool/repository',
    'tina': 'apps/tina_cli',
    'core': 'packages/core',
    'plugin': 'packages/plugin',
    'ui': 'packages/ui',
    'unrelated': 'packages/unrelated',
  };
  final dependencies = {
    'tina_repository_tools': <String>{},
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
            'apps/tina_cli/pubspec.yaml',
            'apps/tina_cli/lib/version.g.dart',
            'packages/plugin/lib/plugin.dart',
          ],
          directories,
          dependencies,
        ),
        {'tina', 'plugin', 'ui'},
      );
    },
  );
  test(
    'application version bumps stay cheap; executable changes run smokes',
    () {
      const files = [
        'apps/tina_cli/pubspec.yaml',
        'apps/tina_cli/lib/version.g.dart',
      ];
      final selected = selectPackages(files, directories, dependencies);
      expect(selected, {'tina'});
      expect(
        needsInteractiveChecks(files, selected, appVersionOnly: true),
        isFalse,
      );
      expect(needsInteractiveChecks(files, selected), isTrue);
      expect(
        needsInteractiveChecks(
          [...files, 'apps/tina_cli/lib/src/cli.dart'],
          selected,
          appVersionOnly: true,
        ),
        isTrue,
      );
      expect(
        selectPackages(
          ['apps/tina_cli/test/cli_test.dart'],
          directories,
          dependencies,
        ),
        {'tina'},
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
      'tool/repository/bin/select_packages.dart',
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
  test('repository test changes need only repository coverage', () {
    expect(
      selectPackages(
        ['tool/repository/test/import_boundary_test.dart'],
        directories,
        dependencies,
      ),
      {'tina_repository_tools'},
    );
  });
  test('known executable smoke fixtures select UI consumers only', () {
    final smokeDirectories = {...directories, 'tina_tui': 'packages/tina_tui'};
    final smokeDependencies = {
      ...dependencies,
      'tina': {'tina_tui'},
      'tina_tui': <String>{},
    };
    for (final file in executableSmokeFiles) {
      expect(selectPackages([file], smokeDirectories, smokeDependencies), {
        'tina_tui',
        'tina',
      }, reason: file);
    }
    expect(
      selectPackages(
        ['tool/smoke_unknown.py'],
        smokeDirectories,
        smokeDependencies,
      ),
      smokeDirectories.keys.toSet(),
      reason: 'New helpers need explicit ownership before narrowing CI',
    );
    expect(
      selectPackages(
        ['tool/smoke_shell.py', 'packages/core/lib/api.dart'],
        smokeDirectories,
        smokeDependencies,
      ),
      {'tina_tui', 'tina', 'core', 'plugin', 'ui'},
      reason: 'Fixture changes must not suppress independent code coverage',
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
      final root = (await repositoryRoot()).path;
      final policy =
          jsonDecode(
                File(
                  path.join(root, 'tool/repository/policy.json'),
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
      expect((jobs['changes'] as Map)['outputs'], contains('full'));
      final native = jobs['linux_interactive'] as Map;
      expect(native['needs'], 'changes');
      expect(native['if'], "needs.changes.outputs.interactive == 'true'");
      expect(
        (native['steps'] as List).cast<Map>().any(
          (step) =>
              (step['run'] as String? ?? '').contains('run_release_smokes.py'),
        ),
        isTrue,
        reason: 'Skipping duplicate JIT checks requires compiled coverage',
      );
      final tuiSteps = ((jobs['tina_cli'] as Map)['steps'] as List).cast<Map>();
      final expanded = tuiSteps.singleWhere(
        (step) =>
            (step['run'] as String? ?? '').contains('--tags tty --run-skipped'),
      );
      expect(expanded['if'], "needs.changes.outputs.full == 'true'");
      final tooling =
          loadYaml(
                File(
                  path.join(root, 'tool/repository/pubspec.yaml'),
                ).readAsStringSync(),
              )
              as Map;
      expect(
        (tooling['dependencies'] as Map).keys,
        unorderedEquals(['analyzer', 'path', 'yaml']),
      );
      expect((tooling['dev_dependencies'] as Map).keys, ['test']);
    },
  );
}
