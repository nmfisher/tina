import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

class PackageRoot {
  final String name, root, library;
  final bool owned;
  PackageRoot(this.name, String root, String library, {this.owned = false})
    : root = canonical(root),
      library = canonical(library);
}

String canonical(String path) {
  final absolute = p.normalize(p.absolute(path));
  return FileSystemEntity.typeSync(absolute) == FileSystemEntityType.notFound
      ? absolute
      : File(absolute).resolveSymbolicLinksSync();
}

bool under(String path, String root) => path == root || p.isWithin(root, path);

class DependencyEdge {
  final String from, to, directive;
  final int line;
  final bool part;
  const DependencyEdge(
    this.from,
    this.to,
    this.directive,
    this.line, {
    this.part = false,
  });
}

class DependencyViolation {
  final String rule, origin, from, target, detail;
  final int line;
  final List<String> path;
  const DependencyViolation(
    this.rule,
    this.origin,
    this.from,
    this.target,
    this.line,
    this.path, [
    this.detail = '',
  ]);
  // Exact edge plus originating policy root: an exception cannot spread to a
  // newly introduced application origin just because it reaches the same edge.
  String get key => '$rule|$origin|$from|$target';
  Map<String, Object> toJson() => {
    'key': key,
    'rule': rule,
    'origin': origin,
    'from': from,
    'target': target,
    'line': line,
    'path': path,
    'detail': detail,
  };
  @override
  String toString() =>
      '$rule: $from:$line${detail.isEmpty ? '' : ' ($detail)'}\n  ${path.join('\n  -> ')}';
}

/// Resolves source imports without loading any application code or native assets.
/// External packages come exclusively from the local package configuration.
class DependencyGraph {
  final String root;
  final Map<String, PackageRoot> packages;
  final Map<String, List<DependencyEdge>> edges = {};
  final List<DependencyViolation> problems = [];
  final Set<String> ownedFiles = {};
  final Map<String, String> _namedLibraries = {};
  final Map<String, String> _namedParts = {};
  final Set<String> _parts = {};
  final Map<String, String> _declaredPartOwners = {};
  final Map<String, Set<String>> _partOwners = {};
  DependencyGraph(String root, this.packages) : root = canonical(root);

  factory DependencyGraph.load(
    String root,
    Set<String> owned, {
    String? contextRoot,
  }) {
    final config = File(
      p.join(contextRoot ?? root, '.dart_tool/package_config.json'),
    );
    final data = jsonDecode(config.readAsStringSync()) as Map;
    final map = <String, PackageRoot>{};
    for (final entry in data['packages'] as List) {
      final name = entry['name'] as String;
      final uri = config.absolute.uri.resolve(entry['rootUri'] as String);
      final directory = Directory.fromUri(uri).uri;
      map[name] = PackageRoot(
        name,
        directory.toFilePath(),
        directory
            .resolve(entry['packageUri'] as String? ?? 'lib/')
            .toFilePath(),
        owned: owned.contains(name),
      );
    }
    return DependencyGraph(root, map);
  }

  PackageRoot? owner(String file) {
    if (file.startsWith('dart:')) return null;
    PackageRoot? found;
    for (final package in packages.values) {
      if (under(file, package.root) &&
          (found == null || package.root.length > found.root.length))
        found = package;
    }
    return found;
  }

  String label(String file) {
    if (file.startsWith('dart:')) return file;
    if (under(file, root)) return p.relative(file, from: root);
    final package = owner(file);
    if (package != null && under(file, package.library)) {
      return 'package:${package.name}/${p.relative(file, from: package.library)}';
    }
    return file;
  }

  void problem(
    String rule,
    String file,
    String target,
    int line,
    String detail,
  ) {
    problems.add(
      DependencyViolation(rule, label(file), label(file), target, line, [
        label(file),
        target,
      ], detail),
    );
  }

  /// Scan all Dart files in declared source roots, including test helpers/tools.
  /// Package directories are enumerated separately to avoid attributing them to root.
  void scan(Map<String, List<String>> roots) {
    for (final entry in roots.entries) {
      final package = packages[entry.key];
      if (package == null)
        throw StateError('Missing source package ${entry.key}');
      for (final relative in entry.value) {
        final directory = Directory(p.join(package.root, relative));
        if (!directory.existsSync())
          throw StateError('Missing classified directory ${directory.path}');
        for (final file in directory.listSync(
          recursive: true,
          followLinks: false,
        )) {
          if (file is Link && !file.path.endsWith('.dart')) {
            problem(
              'source-symlink',
              file.path,
              canonical(file.path),
              1,
              'source directories must not be hidden behind symlinks',
            );
          }
          if (file is Link && file.path.endsWith('.dart')) {
            final resolved = canonical(file.path);
            if (!under(resolved, package.root))
              problem(
                'source-escape',
                file.path,
                resolved,
                1,
                'symlink leaves package',
              );
            else
              ownedFiles.add(resolved);
          }
          if (file is! File || !file.path.endsWith('.dart')) continue;
          final segments = p.split(p.relative(file.path, from: directory.path));
          if (segments.any((s) => s.startsWith('.') || s == 'build')) continue;
          ownedFiles.add(canonical(file.path));
        }
      }
    }
    for (final file in ownedFiles.toList()..sort()) {
      read(file);
    }
    for (final entry in _namedParts.entries.toList()) {
      final library = _namedLibraries[entry.value];
      if (library == null) {
        problem(
          'unresolved-part',
          entry.key,
          entry.value,
          1,
          'named part has no owned library',
        );
      } else {
        _declaredPartOwners[entry.key] = library;
        edges[entry.key]!.add(
          DependencyEdge(
            entry.key,
            library,
            'part of ${entry.value}',
            1,
            part: true,
          ),
        );
      }
    }
    for (final file in ownedFiles) {
      if (_parts.contains(file) &&
          ((_partOwners[file]?.length ?? 0) != 1 ||
              !(_partOwners[file]?.contains(_declaredPartOwners[file]) ??
                  false))) {
        problem(
          'invalid-part',
          file,
          label(file),
          1,
          'part must belong to exactly one library',
        );
      }
    }
  }

  List<DependencyEdge> read(String file) {
    if (file.startsWith('dart:')) return const [];
    if (edges.containsKey(file)) return edges[file]!;
    final out = <DependencyEdge>[];
    edges[file] = out;
    if (!File(file).existsSync()) {
      problem(
        'unresolved-source',
        file,
        label(file),
        1,
        'source does not exist',
      );
      return out;
    }
    final parsed = parseString(
      content: File(file).readAsStringSync(),
      path: file,
      throwIfDiagnostics: false,
    );
    if (parsed.errors.isNotEmpty) {
      problem(
        'malformed-source',
        file,
        label(file),
        parsed.lineInfo.getLocation(parsed.errors.first.offset).lineNumber,
        parsed.errors.first.message,
      );
    }
    for (final directive in parsed.unit.directives) {
      final line = parsed.lineInfo.getLocation(directive.offset).lineNumber;
      if (directive is LibraryDirective && directive.name != null) {
        _namedLibraries[directive.name!.toSource()] = file;
      }
      if (directive is PartOfDirective) {
        _parts.add(file);
        if (directive.uri == null) {
          if (ownedFiles.contains(file))
            _namedParts[file] = directive.libraryName!.toSource();
          continue;
        }
      }
      final values = <String?>[];
      if (directive is UriBasedDirective) values.add(directive.uri.stringValue);
      if (directive is PartOfDirective && directive.uri != null)
        values.add(directive.uri!.stringValue);
      if (directive is NamespaceDirective)
        values.addAll(directive.configurations.map((c) => c.uri.stringValue));
      for (final value in values) {
        if (value == null || value.isEmpty) {
          problem('invalid-uri', file, '$value', line, 'literal URI required');
          continue;
        }
        try {
          final uri = Uri.parse(value);
          if (uri.hasQuery || uri.hasFragment)
            throw FormatException('query/fragment in directive');
          final String target;
          if (uri.scheme == 'dart') {
            target = value;
          } else if (uri.scheme == 'package') {
            final package = packages[uri.pathSegments.first];
            if (package == null)
              throw FormatException(
                'unresolved package ${uri.pathSegments.first}',
              );
            target = canonical(
              File.fromUri(
                Directory(
                  package.library,
                ).uri.resolve(uri.pathSegments.skip(1).join('/')),
              ).path,
            );
            if (!under(target, package.library))
              throw FormatException('package URI escapes library root');
          } else if (!uri.hasScheme &&
              !uri.hasAuthority &&
              !uri.path.startsWith('/')) {
            target = canonical(
              File.fromUri(File(file).uri.resolveUri(uri)).path,
            );
            if (owner(file)?.name != owner(target)?.name) {
              problem(
                'relative-package-escape',
                file,
                label(target),
                line,
                'use a public package URI across packages',
              );
            }
          } else {
            throw FormatException('unsupported source URI $value');
          }
          if (!target.startsWith('dart:') && !File(target).existsSync())
            throw FormatException('missing source ${label(target)}');
          final part =
              directive is PartDirective || directive is PartOfDirective;
          out.add(DependencyEdge(file, target, value, line, part: part));
          if (directive is PartOfDirective) _declaredPartOwners[file] = target;
          if (directive is PartDirective) {
            _partOwners.putIfAbsent(target, () => {}).add(file);
            read(target);
            if (!_parts.contains(target))
              problem(
                'invalid-part',
                file,
                label(target),
                line,
                'part target has no part-of directive',
              );
            edges[target]!.add(
              DependencyEdge(target, file, 'owning library', line, part: true),
            );
          }
        } on FormatException catch (e) {
          problem('invalid-uri', file, value, line, e.message);
        }
      }
    }
    return out;
  }

  /// Breadth-first traversal returns shortest source paths, including exports,
  /// conditional alternatives and part-to-library relationships.
  List<DependencyViolation> forbidden(
    String start,
    String rule,
    bool Function(String target) forbidden, {
    bool transitive = true,
  }) {
    final result = <DependencyViolation>[];
    final queue = Queue<List<String>>()..add([start]);
    final seen = <String>{start};
    while (queue.isNotEmpty) {
      final path = queue.removeFirst();
      for (final edge in read(path.last)) {
        if (forbidden(edge.to)) {
          result.add(
            DependencyViolation(
              rule,
              label(start),
              label(edge.from),
              label(edge.to),
              edge.line,
              [...path.map(label), label(edge.to)],
            ),
          );
        } else if (transitive && seen.add(edge.to)) {
          queue.add([...path, edge.to]);
        }
      }
    }
    return result;
  }

  Map<String, Set<String>> manifestDependencies({bool includeDev = false}) {
    final result = <String, Set<String>>{};
    for (final package in packages.values) {
      final file = File(p.join(package.root, 'pubspec.yaml'));
      if (!file.existsSync()) throw StateError('Missing manifest ${file.path}');
      final yaml = loadYaml(file.readAsStringSync()) as YamlMap;
      if (yaml['name'] != package.name)
        throw StateError('Package config/manifest name mismatch: ${file.path}');
      result[package.name] = {
        ...((yaml['dependencies'] as YamlMap?)?.keys.cast<String>() ??
            const <String>[]),
        if (includeDev &&
            ownedFiles.any((file) => owner(file)?.name == package.name))
          ...((yaml['dev_dependencies'] as YamlMap?)?.keys.cast<String>() ??
              const <String>[]),
      };
      for (final dependency in result[package.name]!) {
        if (!packages.containsKey(dependency))
          throw StateError(
            'Unresolved manifest dependency ${package.name} -> $dependency',
          );
      }
    }
    return result;
  }
}
