import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../tool/architecture/dependency_graph.dart';
import '../../tool/architecture/policy.dart';

class Fixture {
  final Directory directory = Directory.systemTemp.createTempSync(
    'tina-graph-',
  );
  final Map<String, PackageRoot> packages = {};
  late final String root = canonical(directory.path);
  Fixture() {
    package('tina');
    package('engine');
    package('console');
  }
  void package(
    String name, {
    List<String> dependencies = const [],
    List<String> dev = const [],
  }) {
    final path = name == 'tina' ? root : p.join(root, 'packages', name);
    Directory(p.join(path, 'lib')).createSync(recursive: true);
    File(p.join(path, 'pubspec.yaml')).writeAsStringSync(
      'name: $name\n'
      '${dependencies.isEmpty ? '' : 'dependencies:\n${dependencies.map((n) => '  $n: any\n').join()}'}'
      '${dev.isEmpty ? '' : 'dev_dependencies:\n${dev.map((n) => '  $n: any\n').join()}'}',
    );
    packages[name] = PackageRoot(name, path, p.join(path, 'lib'), owned: true);
  }

  String write(String path, String source) {
    final file = File(p.join(root, path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(source);
    return canonical(file.path);
  }

  ArchitecturePolicy policy([Map<String, dynamic> extra = const {}]) =>
      ArchitecturePolicy({
        'ownedPackages': packages.keys.toList(),
        'sourceRoots': {
          for (final name in packages.keys) name: ['lib'],
        },
        'terminalPackages': ['console'],
        'frontendRoots': ['lib/tui/'],
        'assemblyRoots': ['lib/composition/'],
        'serviceRoots': ['lib/application/'],
        'finalComposition': ['lib/composition/app.dart'],
        ...extra,
      });
  DependencyGraph graph({Map<String, List<String>>? roots}) =>
      DependencyGraph(root, packages)..scan(
        roots ??
            {
              for (final name in packages.keys) name: ['lib'],
            },
      );
  List<DependencyViolation> check() => policy().check(graph());
  void close() => directory.deleteSync(recursive: true);
}

void main() {
  late Fixture f;
  setUp(() => f = Fixture());
  tearDown(() => f.close());

  test(
    'multiline imports, exports and inactive conditional branches use shortest paths',
    () {
      f.write('packages/console/lib/console.dart', '');
      final start = f.write(
        'lib/start.dart',
        "import\n 'long.dart';\nexport 'helper.dart';",
      );
      f.write('lib/long.dart', "export 'helper.dart';");
      f.write(
        'lib/helper.dart',
        "export 'empty.dart'\n if (dart.library.io) 'package:console/console.dart';",
      );
      f.write('lib/empty.dart', '');
      final found = f.graph().forbidden(
        start,
        'frontend-exclusion',
        (file) => f.packages['console']!.root == f.graph().owner(file)?.root,
      );
      expect(found, hasLength(1));
      expect(found.single.path, [
        'lib/start.dart',
        'lib/helper.dart',
        'packages/console/lib/console.dart',
      ]);
      expect(found.single.from, 'lib/helper.dart');
      expect(found.single.line, 1);
    },
  );

  test('new test helpers and new application files are guarded by default', () {
    f.write('packages/console/lib/console.dart', '');
    f.write('test/new_test.dart', "import 'helpers/new_helper.dart';");
    f.write(
      'test/helpers/new_helper.dart',
      "import 'package:console/console.dart';",
    );
    f.write(
      'lib/new_directory/new.dart',
      "import 'package:console/console.dart';",
    );
    final graph = f.graph(
      roots: {
        'tina': ['lib', 'test'],
        'console': ['lib'],
        'engine': ['lib'],
      },
    );
    final origins = f
        .policy()
        .check(graph)
        .where((v) => v.rule == 'frontend-exclusion')
        .map((v) => v.origin);
    expect(
      origins,
      containsAll([
        'test/new_test.dart',
        'test/helpers/new_helper.dart',
        'lib/new_directory/new.dart',
      ]),
    );
  });

  test(
    'parts inherit owning library dependencies for URI and named libraries',
    () {
      f.write('packages/console/lib/console.dart', '');
      f.write(
        'lib/a.dart',
        "library a; import 'package:console/console.dart'; part 'a_part.dart';",
      );
      f.write('lib/a_part.dart', 'part of a;');
      f.write(
        'lib/b.dart',
        "import 'package:console/console.dart'; part 'b_part.dart';",
      );
      f.write('lib/b_part.dart', "part of 'b.dart';");
      final violations = f.check();
      expect(violations.where((v) => v.rule.contains('part')), isEmpty);
      expect(
        violations
            .where((v) => v.rule == 'frontend-exclusion')
            .map((v) => v.origin),
        containsAll(['lib/a_part.dart', 'lib/b_part.dart']),
      );
      expect(violations.where((v) => v.rule == 'package-cycle'), isEmpty);
    },
  );

  test('orphan and mismatched parts fail closed', () {
    f.write('lib/orphan.dart', 'part of missing;');
    f.write('lib/a.dart', "part 'piece.dart';");
    f.write('lib/b.dart', '');
    f.write('lib/piece.dart', "part of 'b.dart';");
    expect(
      f.check().map((v) => v.rule),
      containsAll(['unresolved-part', 'invalid-part']),
    );
  });

  test('missing, malformed and unresolved sources are diagnosed', () {
    f.write(
      'lib/a.dart',
      "import 'missing.dart'; import 'package:unknown/a.dart';",
    );
    f.write('lib/b.dart', 'class {');
    expect(
      f.check().map((v) => v.rule),
      containsAll(['invalid-uri', 'malformed-source']),
    );
    expect(
      () => f.graph(
        roots: {
          'tina': ['missing'],
        },
      ),
      throwsStateError,
    );
  });

  test('package traversal and absolute source URIs are rejected', () {
    f.write('packages/engine/outside.dart', '');
    f.write(
      'lib/a.dart',
      "import 'package:engine/%2e%2e/outside.dart'; import 'file:///tmp/no.dart';",
    );
    expect(f.check().where((v) => v.rule == 'invalid-uri'), hasLength(2));
  });

  test('private libraries are allowed within their package only', () {
    f.write('packages/engine/lib/src/private.dart', '');
    f.write('packages/engine/lib/engine.dart', "export 'src/private.dart';");
    f.write('lib/a.dart', "import 'package:engine/src/private.dart';");
    f.write('lib/b.dart', "import '../packages/engine/lib/src/private.dart';");
    final violations = f.check();
    expect(
      violations.where((v) => v.rule == 'public-api').map((v) => v.origin),
      unorderedEquals(['lib/a.dart', 'lib/b.dart']),
    );
    expect(
      violations.where((v) => v.rule == 'relative-package-escape'),
      hasLength(1),
    );
  });

  test(
    'frontend and assembly exceptions do not exempt their application callers',
    () {
      f.write('packages/console/lib/console.dart', '');
      f.write('lib/tui/view.dart', "import 'package:console/console.dart';");
      f.write('lib/composition/app.dart', "import '../tui/view.dart';");
      f.write(
        'lib/application/service.dart',
        "import '../composition/app.dart';",
      );
      final violations = f.check();
      expect(violations.map((v) => v.origin).toSet(), {
        'lib/application/service.dart',
      });
      expect(
        violations.map((v) => v.rule),
        containsAll(['frontend-exclusion', 'assembly-direction']),
      );
    },
  );

  test(
    'unused terminal manifest dependencies are forbidden; dev dependencies are separate',
    () {
      f.write('packages/console/lib/console.dart', '');
      f.package('engine', dependencies: ['console']);
      expect(
        f.check().where((v) => v.rule == 'manifest-direction'),
        hasLength(1),
      );
      f.package('engine', dev: ['console']);
      expect(f.check(), isEmpty);
      f.write(
        'packages/engine/lib/a.dart',
        "import 'package:console/console.dart';",
      );
      expect(f.check().map((v) => v.rule), contains('frontend-exclusion'));
    },
  );

  test(
    'source and manifest cycles are rejected but dev edges do not create cycles',
    () {
      f.package('tina', dependencies: ['engine']);
      f.package('engine', dev: ['tina']);
      expect(f.check(), isEmpty);
      f.write('lib/a.dart', "import 'package:engine/a.dart';");
      f.write('packages/engine/lib/a.dart', "import 'package:tina/a.dart';");
      expect(
        f.check().map((v) => v.rule),
        containsAll(['package-cycle', 'package-direction']),
      );
      f.package('engine', dependencies: ['tina']);
      expect(f.check().map((v) => v.rule), contains('manifest-direction'));
    },
  );

  test('unresolved manifest dependencies fail even when unused', () {
    f.package('engine', dependencies: ['unknown']);
    expect(f.check, throwsStateError);
  });

  test(
    'workspace discovery rejects new source roots and unclassified packages',
    () {
      final policy = f.policy({
        'frontendRoots': [],
        'assemblyRoots': [],
        'serviceRoots': [],
        'finalComposition': [],
      });
      policy.validateWorkspace(f.root);
      final file = f.write('new_sources/a.dart', '');
      expect(() => policy.validateWorkspace(f.root), throwsStateError);
      File(file).deleteSync();
      f.write('packages/new_package/pubspec.yaml', 'name: new_package');
      expect(() => policy.validateWorkspace(f.root), throwsStateError);
    },
  );

  test('stale classified paths and omitted owned packages fail', () {
    expect(() => f.policy().validateWorkspace(f.root), throwsStateError);
    expect(
      () => f
          .policy({
            'sourceRoots': {
              'tina': ['lib'],
            },
          })
          .validateWorkspace(f.root),
      throwsStateError,
    );
  });

  test(
    'local package configuration resolves relative roots and packageURI',
    () {
      f.write(
        '.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'tina', 'rootUri': '../', 'packageUri': 'lib/'},
            {
              'name': 'engine',
              'rootUri': '../packages/engine/',
              'packageUri': 'lib/',
            },
          ],
        }),
      );
      f.write('packages/engine/lib/a.dart', '');
      final start = f.write('lib/a.dart', "import 'package:engine/a.dart';");
      final graph = DependencyGraph.load(f.root, {'tina', 'engine'})
        ..scan({
          'tina': ['lib'],
        });
      expect(
        graph.read(start).single.to,
        p.join(f.root, 'packages/engine/lib/a.dart'),
      );
    },
  );

  test(
    'baseline is exact, justified, task-owned and fails on stale entries',
    () {
      const v = DependencyViolation('frontend-exclusion', 'a', 'b', 'c', 4, [
        'a',
        'b',
        'c',
      ]);
      final entry = {
        'key': v.key,
        'reason': 'Migrate compatibility fixture',
        'owner': 'A06',
      };
      expect(applyBaseline([v], [entry]), isEmpty);
      expect(applyBaseline([], [entry]), isNotEmpty);
      expect(applyBaseline([v], [entry, entry]), isNotEmpty);
      expect(
        applyBaseline(
          [v],
          [
            {...entry, 'reason': ''},
          ],
        ),
        isNotEmpty,
      );
      expect(
        applyBaseline(
          [v],
          [
            {...entry, 'owner': 'someday'},
          ],
        ),
        isNotEmpty,
      );
      expect(
        applyBaseline(
          [v],
          [
            {...entry, 'key': 'frontend-exclusion|*'},
          ],
        ),
        isNotEmpty,
      );
      const newOrigin = DependencyViolation(
        'frontend-exclusion',
        'new',
        'b',
        'c',
        4,
        ['new', 'b', 'c'],
      );
      expect(applyBaseline([v, newOrigin], [entry]), hasLength(1));
      const invalid = DependencyViolation(
        'invalid-uri',
        'a',
        'a',
        'missing',
        1,
        ['a', 'missing'],
      );
      expect(
        applyBaseline(
          [invalid],
          [
            {...entry, 'key': invalid.key},
          ],
        ),
        isNotEmpty,
      );
    },
  );
}
