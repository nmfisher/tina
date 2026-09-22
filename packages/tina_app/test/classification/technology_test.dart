import 'dart:convert';
import 'dart:io';

import 'package:classifier/classification.dart';
import 'package:classifier/judgments.dart';
import 'package:test/test.dart';
import 'package:tina_app/classification.dart';
import 'package:tina_engine/tina_engine.dart';

class Service implements JudgmentService {
  final requests = <JudgmentRequest>[];
  Map<String, double>? probabilities;
  @override
  Future<JudgmentResult> evaluate(
    JudgmentRequest request, {
    JudgmentCancellation? cancellation,
  }) async {
    requests.add(request);
    final text = jsonEncode(request.state.value);
    return JudgmentResult.fromJson({
      'model': 'test',
      'usage': {},
      'answers': {
        for (final key in request.questions.keys)
          key: {
            'type': 'noul',
            'noul':
                probabilities?[key] ??
                (text.contains('uses:$key') ? 0.99 : 0.01),
          },
      },
    }, request: request);
  }
}

void main() {
  test('framework candidates depend on language; tooling does not', () {
    expect(
      frameworkCandidates(['python']).keys,
      containsAll(['fastapi', 'django', 'flask']),
    );
    expect(frameworkCandidates(['python']).keys, isNot(contains('flutter')));
    expect(frameworkCandidates(['dart']).keys, contains('flutter'));
    expect(frameworkCandidates(['typescript']).keys, contains('react'));
    expect(frameworkCandidates([]), hasLength(frameworks.length));
    expect(frameworkCandidates(['other']), hasLength(frameworks.length));
    expect(tooling, contains('docker'));
  });

  test(
    'multiple findings, other, unknown and none have distinct meanings',
    () async {
      final service = Service();
      final executor = JudgmentExecutor(
        service: service,
        budget: JudgmentRequestBudget(),
        identity: 'test',
      );
      Future<ClassificationResult<ProjectLabels>> run(
        Map<String, double> values, {
        bool complete = true,
      }) {
        service.probabilities = values;
        return executor.execute(
          ClassificationRequest(
            frameworkClassifier(['python']),
            ClassificationInput(
              [
                SourceUnit(
                  'manifest',
                  TextEvidence('manifest', 'dependencies'),
                ),
              ],
              InputCoverage(
                complete: complete,
                gaps: complete ? [] : ['unreadable file'],
              ),
            ),
          ),
          JudgmentCancellation(),
          maxInputTokens: 24000,
          maxOutputTokens: 1024,
        );
      }

      expect(
        (await run({
          'fastapi': 0.99,
          'flask': 0.8,
        })).value!.labels.map((l) => l.value),
        ['fastapi', 'flask'],
      );
      expect((await run({'other': 0.99})).value!.labels.single.value, 'other');
      expect(
        (await run({'unknown': 0.99})).outcome,
        ClassificationOutcome.unknown,
      );
      expect(
        (await run({'fastapi': 0.5})).outcome,
        ClassificationOutcome.unknown,
      );
      expect(
        (await run({'none': 0.99})).outcome,
        ClassificationOutcome.notApplicable,
      );
      expect(
        (await run({'none': 0.99}, complete: false)).outcome,
        ClassificationOutcome.unknown,
      );
      expect(
        (await run({'none': 0.99, 'unknown': 0.99})).outcome,
        ClassificationOutcome.unknown,
      );
      expect(
        (await run({'none': 0.99, 'fastapi': 0.9})).value!.labels.single.value,
        'fastapi',
      );
    },
  );

  test(
    'three dimensions persist and restore, changing only affected branches',
    () async {
      final root = await Directory.systemTemp.createTemp('technology-tree-');
      addTearDown(() => root.delete(recursive: true));
      await Process.run('git', ['init', '-q', root.path]);
      Future<void> write(String name, String text) async {
        final file = File('${root.path}/$name');
        await file.parent.create(recursive: true);
        await file.writeAsString(text);
      }

      await write('api/main.py', 'not sent');
      await write('api/requirements.txt', 'uses:fastapi');
      await write('app/main.dart', 'not sent');
      await write('app/pubspec.yaml', 'uses:flutter');
      await write('Dockerfile', 'uses:docker');
      await write('assets/blob.bin', 'x' * 200000);
      final reader = RepositoryEvidenceReader(
        root: root.path,
        sandbox: SandboxedFileSystem(
          const IoFileSystem(),
          workspaceRoot: root.path,
          tinaDir: Directory('${root.path}/.tina'),
        ),
      );
      final source = RepositoryTextSource(
        reader: reader,
        projection: RepositoryProjection.filenames,
      );
      final details = RepositoryTextSource(reader: reader, selectedOnly: true);
      final service = Service();
      final store = await SqliteClassificationStore.open(
        root.path,
        create: true,
      );
      addTearDown(store.close);
      Future<ProjectClassificationReport> run({bool status = false}) =>
          ClassificationOrchestrator(
            store: store,
            executor: LocalExecutor(
              fallback: JudgmentExecutor(
                service: service,
                budget: JudgmentRequestBudget(),
                identity: 'test',
              ),
            ),
          ).run(
            (session) => classifyProject(
              session,
              source,
              local: SingleRequestPlan(extensionClassifier()),
              detailsSource: details,
            ),
            restoreOnly: status,
          );
      List<String> labels(ProjectClassificationReport report, String key) =>
          report.records[key]!.result.value!.labels
              .map((l) => l.value)
              .toList();
      final first = await run();
      expect(first.failures, isEmpty);
      expect(labels(first, '.::language'), ['dart', 'python']);
      expect(labels(first, '.::framework'), ['fastapi', 'flutter']);
      expect(labels(first, '.::tooling'), ['docker']);
      expect(
        first.records['assets::framework']!.result.outcome,
        ClassificationOutcome.unknown,
      );
      expect(
        service.requests,
        hasLength(6),
      ); // Two classifications per evidence directory.
      expect(
        jsonEncode(service.requests.map((r) => r.state.value).toList()),
        isNot(contains('blob.bin')),
      );
      final python = service.requests.firstWhere(
        (r) =>
            r.questions.containsKey('fastapi') &&
            jsonEncode(r.state.value).contains('requirements.txt'),
      );
      expect(python.questions, isNot(contains('flutter')));
      final restored = await run(status: true);
      expect(restored.failures, isEmpty);
      expect(restored.executed, 0);
      expect(service.requests, hasLength(6));
      final pointers = (await store.readManifest())!['records'] as Map;
      expect(
        pointers.keys,
        containsAll([
          'task:.::language',
          'task:.::framework',
          'task:.::tooling',
        ]),
      );
      service.requests.clear();
      await write('api/requirements.txt', 'uses:django');
      final stale = await run(status: true);
      expect(stale.failures, isNotEmpty);
      expect(service.requests, isEmpty);
      final changed = await run();
      expect(changed.failures, isEmpty);
      expect(labels(changed, '.::framework'), ['django', 'flutter']);
      expect(service.requests, hasLength(2));
      expect(
        changed.records['app::framework']!.id,
        first.records['app::framework']!.id,
      );
      expect(
        changed.records['.::language']!.id,
        first.records['.::language']!.id,
      );
      // Changing the language narrows candidates and invalidates its framework task.
      service.requests.clear();
      await File('${root.path}/api/main.py').delete();
      await write('api/main.dart', '');
      await run();
      final newFramework = service.requests.firstWhere(
        (r) => r.questions.containsKey('flutter'),
      );
      expect(newFramework.questions, isNot(contains('fastapi')));
      // Removing a subtree retires all three active pointers.
      await Directory('${root.path}/app').delete(recursive: true);
      final removed = await run();
      expect(removed.failures, isEmpty);
      final after = (await store.readManifest())!['records'] as Map;
      expect(
        after.keys.where((k) => k.toString().startsWith('task:app::')),
        isEmpty,
      );
    },
  );
}
