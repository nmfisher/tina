import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:tina_repository_tools/src/architecture/dependency_graph.dart';
import 'package:tina_repository_tools/src/architecture/policy.dart';

/// A minimal self-contained workspace: packages register by name, sources
/// land under `packages/<name>/lib`, and the policy/graph pair can be built
/// with extra policy keys — the same harness shape the dependency-graph
/// tests use, trimmed to what the io-boundary rule needs.
final class _Fixture {
  late final Directory directory;
  late final String root;
  final packages = <String, PackageRoot>{};

  _Fixture() {
    directory = Directory.systemTemp.createTempSync('arch_io_fixture_');
    root = directory.path;
  }

  void package(String name) {
    final path = p.join(root, 'packages', name);
    Directory(p.join(path, 'lib')).createSync(recursive: true);
    File(p.join(path, 'pubspec.yaml')).writeAsStringSync('name: $name\n');
    packages[name] = PackageRoot(name, path, p.join(path, 'lib'), owned: true);
  }

  String write(String path, String source) {
    final file = File(p.join(root, path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(source);
    return canonical(file.path);
  }

  ArchitecturePolicy policy() => ArchitecturePolicy({
        'ownedPackages': packages.keys.toList(),
        'sourceRoots': {
          for (final name in packages.keys) name: ['lib'],
        },
        'noDirectIoPackages': ['engine'],
      });

  DependencyGraph graph() => DependencyGraph(root, packages)
    ..scan({
      for (final name in packages.keys) name: ['lib'],
    });

  void close() => directory.deleteSync(recursive: true);
}

void main() {
  late _Fixture f;
  setUp(() => f = _Fixture());
  tearDown(() => f.close());

  test('an engine package lib importing dart:io is a service-io violation',
      () {
    f.package('engine');
    f.package('other');
    f.write('packages/engine/lib/engine.dart', "import 'dart:io';");
    f.write('packages/other/lib/other.dart', "import 'dart:io';");
    final violations = f
        .policy()
        .check(f.graph())
        .where((v) => v.rule == 'service-io')
        .toList();
    // Only the listed package's lib tree is gated; `other` may import io.
    expect(
      violations.map((v) => v.key),
      ['service-io|packages/engine/lib/engine.dart|packages/engine/lib/engine.dart|dart:io'],
    );
  });

  test('the package rule is direct-only, like the file-list rule', () {
    // What a dependency does inside its own sources is that package's
    // boundary: importing a file that itself imports dart:io is not a
    // violation for the importer, only for the file that names it.
    f.package('engine');
    f.write('packages/engine/lib/helper.dart', "import 'dart:io';");
    f.write('packages/engine/lib/engine.dart', "import 'helper.dart';");
    final violations = f
        .policy()
        .check(f.graph())
        .where((v) => v.rule == 'service-io')
        .toList();
    expect(
      violations.map((v) => v.key),
      ['service-io|packages/engine/lib/helper.dart|packages/engine/lib/helper.dart|dart:io'],
    );
  });

  test('engine package tests may use dart:io', () {
    f.package('engine');
    f.write('packages/engine/lib/engine.dart', '');
    f.write('packages/engine/test/engine_test.dart', "import 'dart:io';");
    final violations = f
        .policy()
        .check(f.graph())
        .where((v) => v.rule == 'service-io')
        .toList();
    expect(violations, isEmpty);
  });

  test('unowned packages cannot be listed as io-free', () {
    f.package('engine');
    final policy = ArchitecturePolicy({
      'ownedPackages': f.packages.keys.toList(),
      'sourceRoots': {
        for (final name in f.packages.keys) name: ['lib'],
      },
      'noDirectIoPackages': ['stranger'],
    });
    expect(
      () => policy.validateWorkspace(f.root),
      throwsA(isA<StateError>()),
    );
  });
}
