import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_app/src/composition/execution_runtime.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_environment.dart';
import '../helpers/fake_host_interface.dart';
import '../helpers/fake_provider.dart';
import '../helpers/memory_session_store.dart';

class _ScriptedDriver implements AgentDriver {
  _ScriptedDriver(this.request) : provider = request.provider;
  final AgentDriverRequest request;
  int runs = 0;

  @override
  LlmProvider provider;
  @override
  String? get abortedReason => null;
  @override
  AbortedKind get abortedKind => AbortedKind.none;
  @override
  String get system => request.system;
  @override
  ToolRegistry get tools => request.tools;

  @override
  Future<void> run({
    required List<Message> history,
    required String userInput,
    Future<void>? cancelSignal,
    Future<void>? toolInterruptSignal,
    ToolRegistry? turnTools,
  }) async {
    runs++;
    history.add(
      const Message(
        role: Role.assistant,
        content: [TextBlock('restored custom driver')],
      ),
    );
  }

  @override
  Future<bool> compact(
    List<Message> history, {
    int preserveRecent = 0,
    int preserveRecentMessages = 0,
    Future<void>? cancelSignal,
  }) async => false;
}

class _DriverFactory implements AgentDriverFactory {
  final created = <_ScriptedDriver>[];
  @override
  AgentDriver create(AgentDriverRequest request) {
    final driver = _ScriptedDriver(request);
    created.add(driver);
    return driver;
  }
}

class _ReadGuard implements ToolGuard {
  int calls = 0;
  @override
  String? block(String name, Map<String, dynamic> input) {
    calls++;
    return name == 'read' ? 'restored plugin denied read' : null;
  }
}

Future<Conversation> _restore(
  ConversationKind kind,
  FakeProvider provider, {
  AgentDriverFactory? factory,
  ToolGuard? guard,
}) async {
  final root = await Directory.systemTemp.createTemp('tina-restore-plugin-');
  addTearDown(() => root.delete(recursive: true));
  final config = RuntimeConfig();
  final registry = ProviderRegistry(env: const {});
  final environment = FakeEnvironment();
  final runtime = await buildExecutionRuntime(
    config: config,
    registry: registry,
    projectRoot: root.path,
    environment: environment,
    executionPlugins: [
      ...defaultExecutionPlugins(
        config: config,
        registry: registry,
        providerDecorators: const [],
        projectRoot: root.path,
        environment: environment,
        sandboxEnabled: false,
        sandboxNet: false,
        sandboxReadOnly: false,
      ),
      if (factory != null) driverPlugin(factory),
      if (guard != null)
        PluginDescriptor(
          id: 'test.restore-guard',
          factory: FnPluginFactory((context) {
            context.register(guard, id: 'guard');
            return guard;
          }),
        ),
    ],
  );
  addTearDown(runtime.dispose);
  final store = MemorySessionStore();
  final sid = await store.createSession(providerId: 'fake');
  final cid = await store.createConversationWithMeta(
    sid,
    ConversationMetaInput(
      kind: kind,
      promptOverride: 'stored identity',
      policy: PermissionPolicy(
        defaults: {'read': PermissionDecision.allow},
      ).toJson(),
    ),
  );
  await store.append(
    sid,
    cid,
    const Message(role: Role.user, content: [TextBlock('previous input')]),
  );
  final conversation = await restoreConversation(
    store.metaFor(sid, cid)!,
    RestoreContext(
      registry: registry,
      pipeline: runtime.pipeline,
      config: config,
      store: store,
      scheduler: runtime.scheduler,
      hostFactory: ({required conversationId, required isActive}) =>
          FakeHostInterface(),
      sessionId: sid,
      activeConversationId: cid,
      accountProvider: () => provider,
    ),
  );
  addTearDown(conversation.host.dispose);
  addTearDown(conversation.provider.close);
  return conversation;
}

void main() {
  for (final kind in ConversationKind.values) {
    test('restored ${kind.name} runs the mounted driver', () async {
      final factory = _DriverFactory();
      final provider = FakeProvider.done();
      final conversation = await _restore(kind, provider, factory: factory);
      final driver = factory.created.single;
      expect(conversation.driver, same(driver));
      expect(conversation.hasAgent, isFalse);
      expect(driver.provider, same(provider));
      expect(driver.system, 'stored identity');
      expect(driver.tools['read'], isNotNull);
      if (kind != ConversationKind.primary) {
        expect(driver.tools['bash'], isNull);
        expect(
          driver.tools['delegate'] != null,
          kind == ConversationKind.subAgent,
        );
        expect(
          driver.request.policy.check('read', const {}),
          PermissionDecision.allow,
        );
      }
      expect(conversation.history.single.content.single, isA<TextBlock>());
      await conversation.driver.run(
        history: conversation.history,
        userInput: 'continue',
      );
      expect(driver.runs, 1);
      expect(provider.calls, isEmpty);
      expect(
        (conversation.history.first.content.single as TextBlock).text,
        'previous input',
      );
      expect(
        (conversation.history.last.content.single as TextBlock).text,
        'restored custom driver',
      );
    });

    test(
      'restored ${kind.name} enforces a mounted guard with the default driver',
      () async {
        final guard = _ReadGuard();
        final provider = FakeProvider(const [
          [
            MessageComplete(
              content: [
                ToolUseBlock(
                  id: 'r',
                  name: 'read',
                  input: {'path': 'should-not-be-read'},
                ),
              ],
              stopReason: 'tool_use',
            ),
          ],
          [
            MessageComplete(content: [TextBlock('done')], stopReason: 'stop'),
          ],
        ]);
        final conversation = await _restore(kind, provider, guard: guard);
        await conversation.driver.run(
          history: conversation.history,
          userInput: 'read',
        );
        expect(guard.calls, greaterThan(0));
        final result = conversation.history
            .expand((m) => m.content)
            .whereType<ToolResultBlock>()
            .single;
        expect(result.isError, isTrue);
        expect(result.content, 'restored plugin denied read');
      },
    );
  }
}
