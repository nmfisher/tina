import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_app/src/session/conversation_operations.dart';
import 'package:tina_app/src/config/runtime_config.dart';
import 'package:tina_app/src/session/conversation.dart';
import 'package:tina_app/src/session/session_manager.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_host_interface.dart';
import '../helpers/fake_provider.dart';
import '../helpers/memory_session_store.dart';

class _Provider extends FakeProvider {
  int closes = 0;
  bool failClose = false;
  _Provider(String model) : super(const [], model: model);
  @override
  void close() {
    closes++;
    if (failClose) throw StateError('close failed');
  }
}

class _Factory implements LlmProviderFactory {
  final built = <_Provider>[];
  bool fail = false;
  int? seenMaxTokens;
  Duration? seenIdleTimeout;
  @override
  LlmProvider build(
    String reference, {
    String? apiKeyOverride,
    String? baseUrlOverride,
    int? maxTokens,
    Duration? streamIdleTimeout,
    Duration? requestTimeout,
  }) {
    if (fail) throw StateError('provider failed');
    seenMaxTokens = maxTokens;
    seenIdleTimeout = streamIdleTimeout;
    final result = _Provider(reference.split('/').last);
    built.add(result);
    return result;
  }
}

class _Store extends MemorySessionStore {
  bool failCreate = false;
  bool failReplace = false;
  bool failModel = false;
  bool failDelete = false;
  Future<void> Function()? beforeCreate;
  @override
  Future<String> createConversationWithMeta(
    String id,
    ConversationMetaInput meta,
  ) async {
    if (failCreate) throw StateError('create failed');
    await beforeCreate?.call();
    return super.createConversationWithMeta(id, meta);
  }

  @override
  Future<void> replace(String sid, String cid, List<Message> messages) async {
    if (failReplace) throw StateError('replace failed');
    await super.replace(sid, cid, messages);
  }

  @override
  Future<void> deleteConversation(String sid, String cid) async {
    if (failDelete) throw StateError('delete failed');
    await super.deleteConversation(sid, cid);
  }

  @override
  Future<void> updateConversationModel(
    String sid,
    String cid, {
    required String model,
    String? label,
  }) async {
    if (failModel) throw const FileSystemException('model failed');
    await super.updateConversationModel(sid, cid, model: model, label: label);
  }
}

void main() {
  late _Store store;
  late _Factory factory;
  late SessionManager manager;
  late Conversation source;
  late ConversationOperations operations;
  late String sid;
  late List<FakeHostInterface> hosts;
  late bool failHost;

  Future<void> setup({
    bool safeMode = false,
    PermissionMode mode = PermissionMode.ask,
  }) async {
    store = _Store();
    factory = _Factory();
    hosts = [];
    failHost = false;
    sid = await store.createSession(providerId: 'test');
    final cid = await store.createConversationWithMeta(
      sid,
      const ConversationMetaInput(),
    );
    final provider = _Provider('original');
    final host = FakeHostInterface();
    final policy = PermissionPolicy(mode: mode);
    source = Conversation(
      id: cid,
      label: 'main (original)',
      provider: provider,
      host: host,
      policy: policy,
      agent: Agent(
        provider: provider,
        tools: ToolRegistry([]),
        sink: host,
        policy: policy,
        asker: host.askPermission,
        system: '',
      ),
      recorder: SessionRecorder(store, sid, cid, providerId: 'test')
        ..attach(sid, cid),
    );
    manager = SessionManager(
      initialConversation: source,
      initialProviderId: 'test',
      initialApiKey: '',
      initialSessionId: sid,
      sessionStore: store,
      providerFactory: (_, __, model, ___) => _Provider(model),
      hostFactory: ({required conversationId, required isActive}) =>
          FakeHostInterface(),
      agentBuilder:
          ({
            required conversationId,
            required provider,
            required host,
            required policy,
          }) => AgentDriverAdapter(
            Agent(
              provider: provider,
              tools: ToolRegistry([]),
              sink: host,
              policy: policy,
              asker: host.askPermission,
              system: '',
            ),
          ),
    );
    operations = ConversationOperations(
      sessions: manager,
      config: RuntimeConfig(safeMode: safeMode, permissionMode: mode),
      pipeline: AgentPipeline(
        promptContext: PromptContext(loadProjectContext: false),
      ),
      providers: factory,
      store: store,
      hostFactory: (_) {
        if (failHost) throw StateError('host failed');
        final h = FakeHostInterface();
        hosts.add(h);
        return h;
      },
    );
    addTearDown(manager.closeAll);
  }

  CreateConversationRequest request({ConversationTarget? target}) =>
      CreateConversationRequest(
        target: target ?? ConversationTarget(sid, source.id),
        modelReference: 'test/picked',
        profile: ToolProfile.full,
        promptOverrides: {'main': 'CURRENT IDENTITY'},
      );

  test(
    'spawn preserves tuning, policy, prompt and primary resume anchor',
    () async {
      await setup(safeMode: true);
      source.history.add(
        const Message(role: Role.user, content: [TextBlock('source')]),
      );
      final created = await operations.spawn(request());
      final conv = created.conversation;
      expect(factory.seenMaxTokens, 512);
      expect(factory.seenIdleTimeout, isNull);
      expect(conv.history, isEmpty);
      expect(conv.agent.system, contains('CURRENT IDENTITY'));
      expect(
        conv.agent.tools.all.map((t) => t.schema.name),
        isNot(contains('write')),
      );
      expect(
        conv.agent.tools.all.map((t) => t.schema.name),
        isNot(contains('bash')),
      );
      expect(created.parentConversationId, source.id);
      // The live ref is seeded so sub-agents this conversation spawns inherit
      // its model rather than the build-time parent ref.
      expect(conv.modelReference, 'test/picked');
      expect(manager.activeConversation, same(source));
      expect((await store.loadSession(sid)).activeConversationId, source.id);
      expect(hosts.single.activeChanges, isEmpty);
      expect(store.metaFor(sid, conv.id)!.kind, ConversationKind.spawn);
    },
  );

  test(
    'spawned policy follows mode changes without baking in read-all denial',
    () async {
      await setup(mode: PermissionMode.readAll);
      final conv = (await operations.spawn(request())).conversation;
      expect(conv.agent.policy.check('bash', {}), PermissionDecision.deny);
      source.policy.mode = PermissionMode.ask;
      expect(conv.agent.policy.check('bash', {}), PermissionDecision.ask);
      source.policy.mode = PermissionMode.readAll;
      expect(conv.agent.policy.check('write', {}), PermissionDecision.deny);
    },
  );

  test(
    'branch snapshots once before awaits and keeps its captured source',
    () async {
      await setup();
      final other = (await operations.spawn(request())).conversation;
      final input = <String, dynamic>{
        'nested': <String, dynamic>{'value': 'before'},
      };
      source.history.add(
        Message(
          role: Role.assistant,
          content: [ToolUseBlock(id: 't', name: 'tool', input: input)],
        ),
      );
      source.cancelCompleter =
          Completer<void>(); // running branches are supported
      final target = ConversationTarget(sid, source.id);
      manager.selectConversation(
        other.id,
      ); // picker focus changed before request execution
      store.beforeCreate = () async {
        (input['nested'] as Map)['value'] = 'after';
        source.history.add(
          const Message(role: Role.user, content: [TextBlock('later')]),
        );
      };
      final branch = (await operations.branch(
        request(target: target),
      )).conversation;
      expect(branch.history, hasLength(1));
      expect(
        (branch.history.single.content.single as ToolUseBlock).input['nested'],
        {'value': 'before'},
      );
      expect(await store.loadConversation(sid, branch.id), hasLength(1));
      expect(store.metaFor(sid, branch.id)!.parentConversationId, source.id);
      expect((await store.loadSession(sid)).activeConversationId, source.id);
      expect(manager.activeConversation, same(other));
    },
  );

  for (final failure in ['provider', 'create', 'host', 'replace']) {
    test('$failure failure rolls back only the attempted branch', () async {
      await setup();
      factory.fail = failure == 'provider';
      store.failCreate = failure == 'create';
      failHost = failure == 'host';
      store.failReplace = failure == 'replace';
      await expectLater(operations.branch(request()), throwsStateError);
      expect(manager.active.conversationCount, 1);
      expect((await store.loadSession(sid)).conversations, hasLength(1));
      for (final provider in factory.built) {
        expect(provider.closes, 1);
      }
      for (final host in hosts) {
        expect(host.disposeCalls, 1);
      }
      expect((source.provider as _Provider).closes, 0);
    });
  }

  test(
    'cleanup failure reports the allocated record and still releases resources',
    () async {
      await setup();
      store.failReplace = true;
      store.failDelete = true;
      await expectLater(
        operations.branch(request()),
        throwsA(
          isA<ConversationOperationFailure>().having(
            (e) => e.conversationId,
            'allocated id',
            isNotNull,
          ),
        ),
      );
      expect(manager.active.conversationCount, 1);
      expect((await store.loadSession(sid)).conversations, hasLength(2));
      expect(hosts.single.disposeCalls, 1);
      expect(factory.built.single.closes, 1);
    },
  );

  test(
    'switching sessions does not retarget a captured creation request',
    () async {
      await setup();
      final captured = request();
      final other = await manager.createSession();
      manager.selectSession(other.id);
      final created = await operations.spawn(captured);
      expect(created.sessionId, sid);
      expect(manager.active, same(other));
      expect(other.conversationCount, 1);
      expect((await store.loadSession(sid)).conversations, hasLength(2));
    },
  );

  test(
    'closing the captured session during creation compensates the new record',
    () async {
      await setup();
      final captured = request();
      final other = await manager.createSession();
      manager.selectSession(other.id);
      store.beforeCreate = () async {
        manager.close(sid);
      };
      await expectLater(operations.spawn(captured), throwsStateError);
      expect(manager.active, same(other));
      expect((await store.loadSession(sid)).conversations, hasLength(1));
      expect(factory.built.single.closes, 1);
      expect(hosts, isEmpty);
    },
  );

  test(
    'model replacement failure leaves the original provider untouched',
    () async {
      await setup();
      factory.fail = true;
      final original = source.provider;
      await expectLater(
        operations.changeModel(
          ChangeModelRequest(
            target: ConversationTarget(sid, source.id),
            modelReference: 'test/new',
          ),
        ),
        throwsStateError,
      );
      expect(source.provider, same(original));
      expect(source.agent.provider, same(original));
      expect((original as _Provider).closes, 0);
    },
  );

  test(
    'model change targets captured conversation and preserves immediate busy swap',
    () async {
      await setup();
      final target = ConversationTarget(sid, source.id);
      final side = (await operations.spawn(request())).conversation;
      manager.selectConversation(side.id);
      final original = source.provider as _Provider;
      source.cancelCompleter = Completer<void>();
      final result = await operations.changeModel(
        ChangeModelRequest(target: target, modelReference: 'test/new'),
      );
      expect(result.conversation, same(source));
      expect(original.closes, 1);
      expect(source.agent.provider, same(source.provider));
      expect(source.label, 'main (new)');
      // The swap updates the live ref too, so sub-agents spawned after it
      // inherit the new model.
      expect(source.modelReference, 'test/new');
      expect(source.isRunning, isTrue);
      expect(store.metaFor(sid, source.id)!.model, 'test/new');
      expect(side.provider.model, 'picked');
    },
  );

  test(
    'model cleanup and persistence errors are observable without leaking replacement',
    () async {
      await setup();
      (source.provider as _Provider).failClose = true;
      store.failModel = true;
      final result = await operations.changeModel(
        ChangeModelRequest(
          target: ConversationTarget(sid, source.id),
          modelReference: 'test/new',
        ),
      );
      expect(result.cleanupError, isA<StateError>());
      expect(result.persistenceError, isA<FileSystemException>());
      expect(source.provider, same(factory.built.single));
      expect(source.agent.provider, same(source.provider));
      expect(factory.built.single.closes, 0);
    },
  );

  test(
    'selection changes state without invoking presentation or repointing resume',
    () async {
      await setup();
      final side = (await operations.spawn(request())).conversation;
      final selection = manager.selectConversation(side.id);
      await manager.persistSelection(selection, persist: false);
      expect(selection.previous, same(source));
      expect(selection.next, same(side));
      expect((source.host as FakeHostInterface).activeChanges, isEmpty);
      expect(hosts.single.activeChanges, isEmpty);
      expect((await store.loadSession(sid)).activeConversationId, source.id);
    },
  );
}
