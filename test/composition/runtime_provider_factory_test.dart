import 'dart:io';

import 'package:test/test.dart';
import 'package:tina/composition/app_composition.dart';
import 'package:tina/config.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_environment.dart';
import '../helpers/memory_session_store.dart';

void main() {
  test('overlapping compositions keep startup, classifier and delegate spend '
      'on their own ledgers', () async {
    final temp = Directory.systemTemp.createTempSync('tina-provider-scopes-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final env = {'HOME': '${temp.path}/home'};
    final registry = ProviderRegistry(env: env)
      ..register(
        ProviderDescriptor(
          id: 'test',
          name: 'Test',
          authSources: const [],
          defaultBaseUrl: 'https://example.test',
          builder: (c) => _UsageProvider(c.model),
        ),
      );
    var legacyBuilds = 0;
    final sentinel = (LlmProvider provider) {
      legacyBuilds++;
      return provider;
    };
    registry.decorator = sentinel;

    Future<AppComposition> build(String model) async {
      final app = await buildAppComposition(
        config: Config.parse(
          ['--model', 'test/$model', '--no-sandbox'],
          env: env,
          registry: registry,
        ),
        registry: registry,
        environment: FakeEnvironment(env: env),
        projectRoot: temp.path,
        store: MemorySessionStore(),
      );
      addTearDown(() async {
        app.classifier?.provider.close();
        await app.scheduler.dispose();
        await app.store.close();
      });
      return app;
    }

    final a = await build('a');
    final b = await build('b');
    expect(registry.decorator, same(sentinel));

    // Build after BOTH compositions exist: the older app must not pick up the
    // newer app's ledger when a conversation starts or switches model.
    for (final app in [a, b, a]) {
      final provider = app.buildStartupProvider();
      try {
        await provider.send(system: '', messages: [], tools: []).drain<void>();
      } finally {
        provider.close();
      }
    }
    expect(a.spendLedger.totalTokens, 20);
    expect(b.spendLedger.totalTokens, 10);

    final delegated = await a.scheduler.runStandalone(
      systemPrompt: 'answer',
      task: 'answer',
      parentReference: 'test/a',
      sink: FakeAgentSink(),
    );
    expect(delegated.isError, isFalse);
    expect(a.spendLedger.totalTokens, 30);
    expect(b.spendLedger.totalTokens, 10);

    expect(await b.classifier!.allow('read', {'filePath': 'a'}), isTrue);
    expect(a.spendLedger.totalTokens, 30);
    expect(b.spendLedger.totalTokens, 20);
    expect(legacyBuilds, 0);
    expect(registry.decorator, same(sentinel));
  });
}

class _UsageProvider extends LlmProvider {
  _UsageProvider(super.model);

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    yield const TextDelta('ALLOW');
    yield const MessageComplete(
      content: [TextBlock('ALLOW')],
      stopReason: 'end_turn',
      usage: TokenUsage(inputTokens: 7, outputTokens: 3),
    );
  }
}
