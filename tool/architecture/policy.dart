import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'dependency_graph.dart';

class ArchitecturePolicy {
  final Map<String, dynamic> data;
  ArchitecturePolicy(this.data);
  factory ArchitecturePolicy.read(String path) => ArchitecturePolicy(
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>,
  );
  Set<String> values(String name) =>
      (data[name] as List? ?? []).cast<String>().toSet();
  Map<String, List<String>> get sourceRoots => (data['sourceRoots'] as Map).map(
    (k, v) => MapEntry(k as String, (v as List).cast<String>()),
  );
  bool matches(String file, String roots) => values(roots).any(file.startsWith);

  List<DependencyViolation> check(DependencyGraph graph) {
    final found = <DependencyViolation>[];
    final terminal = values('terminalPackages');
    bool isTerminal(String file) => terminal.contains(graph.owner(file)?.name);
    final runtime = graph.manifestDependencies();
    // Validate dev dependencies resolve too; they are not production graph edges.
    graph.manifestDependencies(includeDev: true);
    final packageEdges = {
      for (final e in runtime.entries) e.key: Set<String>.of(e.value),
    };
    for (final file in graph.ownedFiles.toList()..sort()) {
      final owner = graph.owner(file)!;
      final path = graph.label(file);
      final rootPackage = owner.name == 'tina';
      final frontend =
          terminal.contains(owner.name) ||
          (rootPackage &&
              (matches(path, 'frontendRoots') ||
                  matches(path, 'assemblyRoots') ||
                  values('frontendFiles').contains(path)));
      if (!frontend)
        found.addAll(graph.forbidden(file, 'frontend-exclusion', isTerminal));
      if (rootPackage && matches(path, 'serviceRoots')) {
        found.addAll(
          graph.forbidden(
            file,
            'assembly-direction',
            (f) => values('finalComposition').contains(graph.label(f)),
          ),
        );
      }
      if (!rootPackage)
        found.addAll(
          graph.forbidden(
            file,
            'package-direction',
            (f) => graph.owner(f)?.name == 'tina',
          ),
        );
      if (values('pureFiles').contains(path))
        found.addAll(
          graph.forbidden(file, 'pure-planning', (f) => f == 'dart:io'),
        );
      if (values('noDirectIoFiles').contains(path))
        found.addAll(
          graph.forbidden(
            file,
            'service-io',
            (f) => f == 'dart:io',
            transitive: false,
          ),
        );
      for (final edge in graph.read(file)) {
        final target = graph.owner(edge.to);
        if (target == null || target.name == owner.name) continue;
        if (under(edge.to, p.join(target.library, 'src'))) {
          found.add(
            DependencyViolation(
              'public-api',
              path,
              path,
              graph.label(edge.to),
              edge.line,
              [path, graph.label(edge.to)],
              'cross-package src import: ${edge.directive}',
            ),
          );
        }
        if (under(file, owner.library) && !edge.part)
          packageEdges[owner.name]!.add(target.name);
      }
    }
    for (final package in graph.packages.values.where((p) => p.owned)) {
      final file = graph.label(p.join(package.root, 'pubspec.yaml'));
      if (!terminal.contains(package.name) && package.name != 'tina') {
        for (final chain in _paths(
          runtime,
          package.name,
          (next) => terminal.contains(next) || next == 'tina',
        )) {
          found.add(
            DependencyViolation(
              'manifest-direction',
              file,
              file,
              chain.last,
              1,
              chain,
            ),
          );
        }
      }
      for (final chain in _paths(
        packageEdges,
        package.name,
        (next) => next == package.name,
      )) {
        found.add(
          DependencyViolation(
            'package-cycle',
            file,
            file,
            chain.join(' -> '),
            1,
            chain,
          ),
        );
      }
    }
    found.addAll(graph.problems);
    // Keep the shortest diagnostic for a stable exact origin/edge identity.
    final unique = <String, DependencyViolation>{};
    for (final violation in found) {
      final previous = unique[violation.key];
      if (previous == null || previous.path.length > violation.path.length)
        unique[violation.key] = violation;
    }
    return unique.values.toList()..sort((a, b) => a.key.compareTo(b.key));
  }

  void validateWorkspace(String root) {
    final owned = values('ownedPackages'), vendor = values('vendoredPackages');
    if (sourceRoots.keys.toSet().difference(owned).isNotEmpty ||
        owned.difference(sourceRoots.keys.toSet()).isNotEmpty) {
      throw StateError('Every owned package must have source roots');
    }
    for (final dir in Directory(
      p.join(root, 'packages'),
    ).listSync().whereType<Directory>()) {
      final manifest = File(p.join(dir.path, 'pubspec.yaml'));
      if (manifest.existsSync() &&
          !owned.contains(p.basename(dir.path)) &&
          !vendor.contains(p.basename(dir.path))) {
        throw StateError('Unclassified package ${dir.path}');
      }
    }
    for (final package in owned) {
      final directory = Directory(
        package == 'tina' ? root : p.join(root, 'packages', package),
      );
      final excluded =
          ((data['excludedRoots'] as Map?)?[package] as List? ?? [])
              .cast<String>();
      void visit(Directory dir) {
        for (final entry in dir.listSync(followLinks: false)) {
          final relative = p.relative(entry.path, from: directory.path);
          final name = p.basename(entry.path);
          if (name.startsWith('.') ||
              name == 'build' ||
              (package == 'tina' && relative == 'packages') ||
              excluded.any((e) => under(relative, e)) ||
              sourceRoots[package]!.any((e) => under(relative, e)))
            continue;
          if (entry is Directory) {
            visit(entry);
          } else if (entry.path.endsWith('.dart')) {
            throw StateError('Unclassified source ${entry.path}');
          }
        }
      }

      visit(directory);
    }
    for (final entry in [
      ...values('frontendRoots'),
      ...values('assemblyRoots'),
      ...values('serviceRoots'),
      ...values('frontendFiles'),
      ...values('pureFiles'),
      ...values('noDirectIoFiles'),
      ...values('finalComposition'),
    ]) {
      if (FileSystemEntity.typeSync(p.join(root, entry)) ==
          FileSystemEntityType.notFound)
        throw StateError('Missing classified path $entry');
    }
  }
}

List<List<String>> _paths(
  Map<String, Set<String>> edges,
  String start,
  bool Function(String) forbidden,
) {
  final found = <List<String>>[], queue = Queue<List<String>>()..add([start]);
  final seen = <String>{start};
  while (queue.isNotEmpty) {
    final path = queue.removeFirst();
    for (final next in (edges[path.last] ?? <String>{}).toList()..sort()) {
      if (forbidden(next))
        found.add([...path, next]);
      else if (seen.add(next))
        queue.add([...path, next]);
    }
  }
  return found;
}

/// Baselines name exact origin/edge identities, with a reason and owning task.
/// Removed violations are failures too, so exceptions cannot silently accumulate.
List<String> applyBaseline(
  List<DependencyViolation> violations,
  List<dynamic> baseline,
) {
  final pending = {for (final v in violations) v.key: v};
  final errors = <String>[], seen = <String>{};
  for (final raw in baseline) {
    final entry = raw as Map;
    final key = entry['key'] as String;
    if (!seen.add(key) ||
        key.contains('*') ||
        !const {
          'frontend-exclusion',
          'public-api',
          'relative-package-escape',
          'assembly-direction',
          'package-direction',
          'manifest-direction',
          'package-cycle',
          'pure-planning',
          'service-io',
        }.contains(key.split('|').first) ||
        (entry['reason'] as String? ?? '').trim().isEmpty ||
        !RegExp(r'^A\d\d$').hasMatch(entry['owner'] as String? ?? '')) {
      errors.add('Invalid baseline entry: $key');
      continue;
    }
    if (pending.remove(key) == null) errors.add('Stale baseline entry: $key');
  }
  errors.addAll(pending.values.map((v) => v.toString()));
  return errors;
}

class WorkspaceCheck {
  final List<DependencyViolation> violations;
  final int files;
  WorkspaceCheck(this.violations, this.files);
}

/// Each package's sources and tests use its own dependency resolution, including
/// dev dependencies and version differences. This only reads existing configs.
WorkspaceCheck checkWorkspace(String root, ArchitecturePolicy policy) {
  policy.validateWorkspace(root);
  final violations = <String, DependencyViolation>{};
  var files = 0;
  for (final entry in policy.sourceRoots.entries) {
    final context = entry.key == 'tina'
        ? root
        : p.join(root, 'packages', entry.key);
    final graph = DependencyGraph.load(
      root,
      policy.values('ownedPackages'),
      contextRoot: context,
    );
    graph.scan({entry.key: entry.value});
    files += graph.ownedFiles.length;
    for (final violation in policy.check(graph)) {
      final prior = violations[violation.key];
      if (prior == null || prior.path.length > violation.path.length)
        violations[violation.key] = violation;
    }
  }
  return WorkspaceCheck(
    violations.values.toList()..sort((a, b) => a.key.compareTo(b.key)),
    files,
  );
}
