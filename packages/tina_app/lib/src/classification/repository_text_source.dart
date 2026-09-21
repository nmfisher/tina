import 'dart:convert';

import 'package:classifier/classification.dart';
import 'package:classifier/judgments.dart';

import 'repository_classification_source.dart';
import 'repository_evidence.dart';

enum RepositoryProjection { filenames, filenamesAndContents }

class RepositoryDocument {
  final String path;
  final String? content;
  RepositoryDocument(this.path, [this.content]);
}

class RepositoryTextEncoder
    implements InputEncoder<RepositoryDocument, TextEvidence> {
  const RepositoryTextEncoder();
  @override
  Object get identity => {'id': 'tina.repository_text', 'revision': 1};
  @override
  TextEvidence encode(RepositoryDocument raw) => raw.content == null
      ? TextEvidence('repository-relative filename', raw.path)
      : TextEvidence(
          'complete UTF-8 file content; filename is in location metadata',
          raw.content!,
        );
}

/// Selection and formatting belong to this source adapter. The classifier sees
/// only the TextEvidence contract. A filename-only projection never reads files.
class RepositoryTextSource implements TreeSource<TextEvidence> {
  final RepositoryEvidenceReader reader;
  final RepositoryProjection projection;
  final InputEncoder<RepositoryDocument, TextEvidence> encoder;
  final Set<String> contentNames;
  final List<String> contentSuffixes;
  final int maxContentFiles;
  final int maxContentBytes;
  RepositoryTextSource({
    required this.reader,
    this.projection = RepositoryProjection.filenamesAndContents,
    this.encoder = const RepositoryTextEncoder(),
    Iterable<String> contentNames = projectManifestNames,
    Iterable<String> contentSuffixes = const [
      '.gradle',
      '.gradle.kts',
      '.csproj',
      '.fsproj',
      '.xcodeproj/project.pbxproj',
    ],
    this.maxContentFiles = 64,
    this.maxContentBytes = 1024 * 1024,
  }) : contentNames = Set.unmodifiable(contentNames),
       contentSuffixes = List.unmodifiable(contentSuffixes) {
    if (maxContentFiles < 1 || maxContentBytes < 1)
      throw ArgumentError('Invalid source limits');
  }
  @override
  DataContract<TextEvidence> get contract => textEvidenceContract;
  @override
  InputSplitter<TextEvidence> get splitter => const TextInputSplitter();
  @override
  Object get identity => {
    'id': 'tina.repository_source',
    'revision': 3,
    'projection': projection.name,
    'encoder': encoder.identity,
    'content_names': contentNames.toList()..sort(),
    'content_suffixes': contentSuffixes,
    'max_content_files': maxContentFiles,
    'max_content_bytes': maxContentBytes,
    'splitter': const TextInputSplitter().identity,
  };

  @override
  Future<TreeSnapshot> tree(
    SourceRequest request,
    JudgmentCancellation cancellation,
  ) async {
    if (request.subject != '.') throw ArgumentError('Project tree starts at .');
    if (cancellation.isCancelled) throw StateError('Classification cancelled');
    final view = await reader.scan();
    return TreeSnapshot('.', [
      for (final entry in view.entries.values)
        if (entry.directory)
          Node(
            entry.path,
            input: entry.children.any((key) => !view.entries[key]!.directory)
                ? SourceRequest(entry.path, parameters: {'direct_only': true})
                : null,
            children: entry.children.where(
              (key) => view.entries[key]!.directory,
            ),
          ),
    ], SourceRevision({'names': view.root.names}));
  }

  @override
  Future<bool> isTreeCurrent(
    SourceRevision revision,
    JudgmentCancellation cancellation,
  ) async {
    if (cancellation.isCancelled) return false;
    return (await reader.scan()).root.names == revision.receipt['names'];
  }

  Future<Map<String, Object?>> _observe(EvidenceQuery query) async {
    try {
      final read = await reader.observe(query);
      return {
        'query': query.toJson(),
        'fingerprint': read.fingerprint,
        'value': read.value,
      };
    } catch (e) {
      return {'query': query.toJson(), 'error': e.runtimeType.toString()};
    }
  }

  Map<String, Object?> _receipt(Map<String, Object?> observation) =>
      {...observation}..remove('value');
  @override
  Future<SourceSnapshot<TextEvidence>> snapshot(
    SourceRequest request,
    JudgmentCancellation cancellation,
  ) async {
    if (!validProjectPath(request.subject))
      throw ArgumentError('Invalid repository scope');
    final excluded =
        (request.parameters['excluded_scopes'] as List? ?? const [])
            .cast<String>();
    final query = EvidenceQuery(
      EvidenceKind.listing,
      request.subject,
      excludedScopes: excluded,
      directOnly: request.parameters['direct_only'] == true,
    );
    final inventory = await _observe(query);
    if (inventory.containsKey('error'))
      throw StateError('A complete repository inventory is unavailable');
    final paths = (inventory['value'] as List).cast<String>();
    final receipts = <Map<String, Object?>>[_receipt(inventory)];
    final units = <SourceUnit<TextEvidence>>[
      for (final path in paths)
        SourceUnit(
          'path:$path',
          encoder.encode(RepositoryDocument(path)),
          location: {'path': path},
        ),
    ];
    final gaps = <String>[];
    if (projection == RepositoryProjection.filenamesAndContents) {
      final selected = paths
          .where(
            (p) =>
                contentNames.contains(p.split('/').last) ||
                contentSuffixes.any(p.endsWith),
          )
          .toList();
      var bytes = 0;
      if (selected.length > maxContentFiles)
        gaps.add(
          'Content file limit: selected ${selected.length}, read at most $maxContentFiles.',
        );
      for (final path in selected.take(maxContentFiles)) {
        if (cancellation.isCancelled)
          throw StateError('Classification cancelled');
        final observed = await _observe(
          EvidenceQuery(EvidenceKind.file, path, excludedScopes: excluded),
        );
        receipts.add(_receipt(observed));
        if (observed.containsKey('error') || observed['value'] == null) {
          gaps.add('Content unavailable: $path');
          continue;
        }
        final text = observed['value'] as String;
        bytes += utf8.encode(text).length;
        if (bytes > maxContentBytes) {
          gaps.add('Content byte limit reached at $path.');
          break;
        }
        units.add(
          SourceUnit(
            'file:$path',
            encoder.encode(RepositoryDocument(path, text)),
            location: {'path': path},
          ),
        );
      }
    }
    return SourceSnapshot(
      units: units,
      revision: SourceRevision({'observations': receipts}),
      coverage: InputCoverage(complete: gaps.isEmpty, gaps: gaps),
      splitter: const TextInputSplitter(),
    );
  }

  @override
  Future<bool> isCurrent(
    SourceRevision revision,
    JudgmentCancellation cancellation,
  ) async {
    for (final raw in revision.receipt['observations'] as List) {
      if (cancellation.isCancelled) return false;
      final receipt = jsonObject(raw);
      final query = EvidenceQuery.fromJson(
        Map<String, dynamic>.from(receipt['query'] as Map),
      );
      if (canonicalFingerprint(_receipt(await _observe(query))) !=
          canonicalFingerprint(receipt))
        return false;
    }
    return true;
  }
}

/// This is a project recipe's content selection, not classification machinery.
/// Other applications can supply their own names/suffixes or an entirely
/// different ClassificationSource and InputEncoder.
const projectManifestNames = {
  'pubspec.yaml',
  'pubspec.yml',
  'package.json',
  'Cargo.toml',
  'go.mod',
  'pyproject.toml',
  'requirements.txt',
  'Gemfile',
  'composer.json',
  'pom.xml',
  'Makefile',
  'CMakeLists.txt',
  'build.gradle',
  'settings.gradle',
  'gradle.properties',
  'Dockerfile',
  'angular.json',
  'tsconfig.json',
  'vite.config.ts',
  'vite.config.js',
  'next.config.js',
  'next.config.mjs',
  'jest.config.js',
  'jest.config.ts',
  'pytest.ini',
  'tox.ini',
  'dart_test.yaml',
  'melos.yaml',
  'pnpm-workspace.yaml',
  'lerna.json',
  'nx.json',
  'app.json',
};
