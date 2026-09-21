import '../helpers/memory_session_store.dart';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

class ClassifierProvider extends LlmProvider {
  int calls = 0;
  bool closed = false;
  ClassifierProvider(super.model);
  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    calls++;
    if (calls == 1) {
      yield MessageComplete(
        content: [
          ToolUseBlock(
            id: 'submit',
            name: 'submit_classification',
            input: {
              'outcome': 'unknown',
              'value': null,
              'evidence': <String>[],
              'explanation': 'Insufficient evidence for this dimension.',
            },
          ),
        ],
        stopReason: 'tool_use',
      );
    } else {
      yield const MessageComplete(
        content: [TextBlock('Done')],
        stopReason: 'end_turn',
      );
    }
  }

  @override
  void close() {
    closed = true;
  }
}

void main() {
  test(
    'application composition checkpoints and restores without constructing classifier providers',
    () async {
      final project = await Directory.systemTemp.createTemp(
        'classification-composition-',
      );
      addTearDown(() => project.delete(recursive: true));
      await Process.run('git', ['init', '-q', project.path]);
      await File('${project.path}/README.md').writeAsString('Example');
      final created = <ClassifierProvider>[];
      final registry = ProviderRegistry(env: const {})
        ..register(
          ProviderDescriptor(
            id: 'test',
            name: 'Test',
            authSources: const [],
            defaultBaseUrl: 'https://example.test',
            builder: (options) {
              final provider = ClassifierProvider(options.model);
              created.add(provider);
              return provider;
            },
          ),
        );
      Future<AppComposition> build() => buildAppComposition(
        config: RuntimeConfig(
          provider: 'test',
          model: 'model',
          permissionMode: PermissionMode.readAll,
        ),
        registry: registry,
        store: MemorySessionStore(),
        projectRoot: project.path,
        loadProjectContext: false,
      );
      final first = await build();
      final status = await runProjectClassification(first, mode: 'status');
      expect(status.executed, 0);
      expect(status.records, isEmpty);
      expect(created.every((p) => p.calls == 0), isTrue);
      final baseline = created.length;
      final result = await runProjectClassification(first);
      expect(result.failures, isEmpty);
      expect(result.executed, 1);
      expect(created.skip(baseline), hasLength(1));
      expect(
        created.skip(baseline).every((p) => p.closed && p.calls == 1),
        isTrue,
      );
      await first.dispose();
      final second = await build();
      addTearDown(second.dispose);
      final beforeRestore = created.length;
      final restored = await runProjectClassification(second, mode: 'status');
      expect(restored.restored, 2);
      expect(restored.executed, 0);
      expect(created.length, beforeRestore);
      expect(
        classificationReportText(restored),
        contains('2 classifications restored'),
      );
    },
  );
}
