import 'dart:io';
import 'package:tina_app/classification.dart' show ProjectClassificationReport;
import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';
import '../helpers/memory_session_store.dart';

class Service implements JudgmentService {
  int calls = 0;
  @override
  Future<JudgmentResult> evaluate(
    JudgmentRequest request, {
    JudgmentCancellation? cancellation,
  }) async {
    calls++;
    return JudgmentResult.fromJson({
      'model': 'jev-test',
      'usage': {'input_tokens': 100, 'output_tokens': 50},
      'answers': {
        for (final key in request.questions.keys)
          key: {'type': 'noul', 'noul': 0.5},
      },
    }, request: request);
  }
}

void main() {
  test(
    'index uses judgments and restores independently of the chat model',
    () async {
      final project = await Directory.systemTemp.createTemp(
        'classification-composition-',
      );
      addTearDown(() => project.delete(recursive: true));
      await Process.run('git', ['init', '-q', project.path]);
      await File('${project.path}/README.md').writeAsString('Example');
      final registry = ProviderRegistry(env: const {})
        ..register(
          ProviderDescriptor(
            id: 'test',
            name: 'Test',
            authSources: const [],
            defaultBaseUrl: 'https://example.test',
            builder: (_) =>
                throw StateError('Index must never construct a chat provider'),
          ),
        );
      Future<AppComposition> build(String model) => buildAppComposition(
        config: RuntimeConfig(
          provider: 'test',
          model: model,
          permissionMode: PermissionMode.readAll,
        ),
        registry: registry,
        store: MemorySessionStore(),
        projectRoot: project.path,
        loadProjectContext: false,
      );
      final service = Service();
      Future<ProjectClassificationReport> run(
        AppComposition app, {
        String mode = '',
      }) => runProjectClassification(
        app,
        judgments: service,
        requestBudget: JudgmentRequestBudget(model: 'jev-test'),
        serviceIdentity: 'test-judgments',
        mode: mode,
      );
      final first = await build('slow-chat-model');
      final status = await run(first, mode: 'status');
      expect(status.executed, 0);
      expect(service.calls, 0);
      final result = await run(first);
      expect(result.failures, isEmpty);
      expect(service.calls, 1);
      await first.dispose();
      final second = await build('another-chat-model');
      addTearDown(second.dispose);
      final restored = await run(second, mode: 'status');
      expect(restored.failures, isEmpty);
      expect(restored.restored, 2);
      expect(restored.executed, 0);
      expect(service.calls, 1);
      expect(
        classificationReportText(restored),
        contains('2 classifications restored'),
      );
      final refreshed = await run(second, mode: 'refresh');
      expect(refreshed.failures, isEmpty);
      expect(service.calls, 2);
    },
  );
}
