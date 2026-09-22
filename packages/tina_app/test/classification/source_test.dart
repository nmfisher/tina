import 'dart:io';

import 'package:classifier/classification.dart';
import 'package:classifier/judgments.dart';
import 'package:test/test.dart';
import 'package:tina_app/src/classification/repository_classification_source.dart';
import 'package:tina_app/src/classification/repository_text_source.dart';
import 'package:tina_app/src/classification/repository_evidence.dart';
import 'package:tina_engine/tina_engine.dart';

class CustomEncoder implements InputEncoder<RepositoryDocument, TextEvidence> {
  @override
  Object get identity => {'id': 'custom', 'revision': 2};
  @override
  TextEvidence encode(RepositoryDocument raw) => TextEvidence(
    'custom representation',
    'encoded:${raw.path}:${raw.content?.length ?? 0}',
  );
}

void main() {
  late Directory project;
  late RepositoryEvidenceReader reader;
  final stop = JudgmentCancellation();
  setUp(() async {
    project = await Directory.systemTemp.createTemp('classification-source-');
    await Process.run('git', ['init', '-q', project.path]);
    reader = RepositoryEvidenceReader(
      root: project.path,
      sandbox: SandboxedFileSystem(
        const IoFileSystem(),
        workspaceRoot: project.path,
        tinaDir: Directory('${project.path}/private'),
      ),
    );
    await File('${project.path}/document.txt').writeAsString('old content');
  });
  tearDown(() => project.delete(recursive: true));
  RepositoryTextSource source(
    RepositoryProjection mode, {
    InputEncoder<RepositoryDocument, TextEvidence>? encoder,
  }) => RepositoryTextSource(
    reader: reader,
    projection: mode,
    contentNames: ['document.txt'],
    contentSuffixes: [],
    encoder: encoder ?? const RepositoryTextEncoder(),
  );

  test(
    'names and content projections share the input type but own different freshness dependencies',
    () async {
      final names = source(RepositoryProjection.filenames);
      final contents = source(RepositoryProjection.filenamesAndContents);
      final a = await names.snapshot(SourceRequest('.'), stop);
      final b = await contents.snapshot(SourceRequest('.'), stop);
      expect(
        contractFingerprint(names.contract),
        contractFingerprint(contents.contract),
      );
      expect(a.units.map((u) => u.value.text), ['document.txt']);
      expect(b.units.map((u) => u.value.text), ['document.txt', 'old content']);
      await File('${project.path}/document.txt').writeAsString('new content');
      expect(await names.isCurrent(a.revision, stop), isTrue);
      expect(await contents.isCurrent(b.revision, stop), isFalse);
      await File('${project.path}/another.txt').writeAsString('new');
      expect(await names.isCurrent(a.revision, stop), isFalse);
    },
  );

  test(
    'the source encoder owns text generation and has its own versioned identity',
    () async {
      final encoded = source(
        RepositoryProjection.filenamesAndContents,
        encoder: CustomEncoder(),
      );
      final snapshot = await encoded.snapshot(SourceRequest('.'), stop);
      expect(snapshot.units.last.value.text, 'encoded:document.txt:11');
      expect(snapshot.units.last.value.meaning, 'custom representation');
      expect(
        encoded.identity,
        containsPair('encoder', {'id': 'custom', 'revision': 2}),
      );
    },
  );

  test(
    'file denies apply during source preparation; filename-only sources do not read content',
    () async {
      reader = RepositoryEvidenceReader(
        root: project.path,
        sandbox: SandboxedFileSystem(
          const IoFileSystem(),
          workspaceRoot: project.path,
          tinaDir: Directory('${project.path}/private'),
        ),
        policy: PermissionPolicy(
          mode: PermissionMode.readAll,
          rules: const [
            PermissionRule(
              toolName: 'read',
              pattern: 'document.txt',
              decision: PermissionDecision.deny,
            ),
          ],
        ),
      );
      final names = await source(
        RepositoryProjection.filenames,
      ).snapshot(SourceRequest('.'), stop);
      final contents = await source(
        RepositoryProjection.filenamesAndContents,
      ).snapshot(SourceRequest('.'), stop);
      expect(names.coverage.complete, isTrue);
      expect(contents.coverage.complete, isFalse);
      expect(contents.units.map((u) => u.value.text), ['document.txt']);
      expect(
        contents.coverage.gaps,
        contains('Content unavailable: document.txt'),
      );
    },
  );

  test('source truncation is represented as incomplete coverage', () async {
    final limited = RepositoryTextSource(
      reader: reader,
      contentNames: ['document.txt'],
      maxContentBytes: 3,
    );
    final snapshot = await limited.snapshot(SourceRequest('.'), stop);
    expect(snapshot.coverage.complete, isFalse);
    expect(snapshot.units.length, 1);
  });

  test(
    'hidden paths are excluded at every depth, including tracked files',
    () async {
      for (final path in [
        '.hidden.txt',
        '.config/manifest.txt',
        'src/.private/manifest.txt',
        'src/.hidden.txt',
        'src/visible.txt',
        '.env',
        'credentials.json',
      ]) {
        final file = File('${project.path}/$path');
        await file.parent.create(recursive: true);
        await file.writeAsString('sensitive marker');
      }
      await Process.run('git', ['-C', project.path, 'add', '.']);
      final names = await source(
        RepositoryProjection.filenames,
      ).snapshot(SourceRequest('.'), stop);
      expect(names.units.map((unit) => unit.value.text), [
        'document.txt',
        'src/visible.txt',
      ]);
      final tree = await source(
        RepositoryProjection.filenames,
      ).tree(SourceRequest('.'), stop);
      expect(tree.nodes.keys, unorderedEquals(['.', 'src']));
      for (final path in [
        '.hidden.txt',
        '.config/manifest.txt',
        'src/.private/manifest.txt',
        'src/.hidden.txt',
      ]) {
        await expectLater(
          reader.observe(EvidenceQuery(EvidenceKind.file, path)),
          throwsStateError,
        );
      }
      final hidden = await reader.observe(
        EvidenceQuery(EvidenceKind.listing, 'src/.private'),
      );
      expect(hidden.value, isEmpty);

      final previous = source(RepositoryProjection.filenames);
      reader = RepositoryEvidenceReader(
        root: project.path,
        sandbox: reader.sandbox,
        skipHidden: false,
      );
      final allowed = source(RepositoryProjection.filenames);
      expect(
        canonicalFingerprint(allowed.identity),
        isNot(canonicalFingerprint(previous.identity)),
      );
      expect(await allowed.isCurrent(names.revision, stop), isFalse);
      final all = await allowed.snapshot(SourceRequest('.'), stop);
      expect(
        all.units.map((unit) => unit.value.text),
        unorderedEquals([
          'document.txt',
          '.hidden.txt',
          '.config/manifest.txt',
          'src/.private/manifest.txt',
          'src/.hidden.txt',
          'src/visible.txt',
        ]),
      );
    },
  );

  test(
    'child scopes are excluded by the source, not interpreted by the generic classifier',
    () async {
      await Directory('${project.path}/child').create();
      await File(
        '${project.path}/child/pubspec.yaml',
      ).writeAsString('name: child');
      final snapshot = await source(RepositoryProjection.filenames).snapshot(
        SourceRequest(
          '.',
          parameters: {
            'excluded_scopes': ['child'],
          },
        ),
        stop,
      );
      expect(snapshot.units.map((u) => u.value.text), ['document.txt']);
    },
  );
}
