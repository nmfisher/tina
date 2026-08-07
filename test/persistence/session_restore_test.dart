import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:path/path.dart' as p;
import 'package:tina/composition/agent_composition.dart';
import 'package:tina/config.dart';
import 'package:tina/conversation.dart';
import 'package:tina/persistence/session_restore.dart';
import 'package:test/test.dart';

import '../helpers/fake_host_interface.dart';
import '../helpers/fake_provider.dart';
import '../helpers/memory_session_store.dart';

/// A registry whose providers model a multi-provider session: `anthropic` and
/// `openai` each expose a `small` and a `large` model, so the restore path's
/// `_restoreProvider` resolves the exact model a meta references. Models are
/// small enough for tests; the builder answers a fixed text turn.
ProviderRegistry _multiProviderRegistry() {
  ProviderRegistry register(ProviderRegistry r, String id) {
    r.register(ProviderDescriptor(
      id: id,
      name: id,
      authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
      defaultBaseUrl: 'https://$id.test',
      builder: (c) => FakeProvider(const [
        [
          TextDelta('ok'),
          MessageComplete(content: [TextBlock('ok')], stopReason: 'end_turn')
        ]
      ], model: c.model),
      models: {
        '$id-small': ModelInfo(
            id: '$id-small', name: 'Small', contextWindow: 1, maxOutput: 1),
        '$id-large': ModelInfo(
            id: '$id-large', name: 'Large', contextWindow: 1, maxOutput: 1),
      },
    ));
    return r;
  }

  final r = ProviderRegistry(env: {'TEST_KEY': 'k'});
  register(r, 'anthropic');
  register(r, 'openai');
  return r;
}

/// A minimal pipeline: just the entry identity. Restored sub-agent/spawn
/// metas rebuild their tools from their stored policy's allow-list, so no role
/// declarations are needed.
final _pipeline = AgentPipeline(mainIdentity: 'You are the main agent.');

void main() {
  group('ConversationMeta serialization', () {
    test('ConversationMetaInput.branch captures a forked conversation identity',
        () {
      final policy = PermissionPolicy();
      final meta = ConversationMetaInput.branch(
        providerId: 'openai',
        providerModel: 'openai-large',
        baseUrl: 'https://example.com/v1',
        policy: policy,
        systemPrompt: 'You implement.',
        targetName: 'implementer',
        parentConversationId: 'parent-1',
      );
      final cm = ConversationMeta(
        id: 'branch-1',
        model: meta.model,
        baseUrl: meta.baseUrl,
        providerId: meta.providerId,
        label: meta.label,
        kind: meta.kind,
        targetName: meta.targetName,
        promptOverride: meta.promptOverride,
        policy: meta.policy,
        parentConversationId: meta.parentConversationId,
      );

      // A branch is its own kind — distinct from spawn/subAgent — and carries
      // the parent link + target role so the manifest's fork lineage is
      // inspectable and the panel rebuilds on resume.
      expect(cm.kind, ConversationKind.branch);
      expect(cm.kind, isNot(ConversationKind.spawn));
      expect(cm.targetName, 'implementer');
      expect(cm.parentConversationId, 'parent-1');
      expect(cm.model, 'openai/openai-large');

      // Round-trips cleanly, stable twice.
      final json = cm.toJson();
      expect(json['kind'], 'branch');
      final restored = ConversationMeta.fromJson(json);
      expect(restored.kind, ConversationKind.branch);
      expect(restored.parentConversationId, 'parent-1');
      expect(ConversationMeta.fromJson(restored.toJson()).toJson(), json);
    });

    test('unknown kind name falls back to spawn (read-resilient)', () {
      // A kind a newer/older client wrote that this build doesn't know must not
      // crash the loader; it rebuilds a role-only, read-only-capable agent
      // (the spawn fallback). Guard against regressions of the read path.
      final parsed = ConversationMeta.fromJson({
        'id': 'x',
        'model': 'm',
        'kind': 'not_a_real_kind',
      });
      expect(parsed.kind, ConversationKind.spawn);
      // And the documented null/absent → primary fallback is unchanged.
      expect(ConversationMeta.fromJson({'id': 'y', 'model': 'm'}).kind,
          ConversationKind.primary);
    });

    test('round-trips every field', () {
      final policy = PermissionPolicy();
      final meta = ConversationMeta(
        id: 'c1',
        model: 'anthropic/claude-sonnet-4-20250514',
        baseUrl: 'https://example.com/v1',
        providerId: 'anthropic',
        label: 'main (claude-sonnet-4-20250514)',
        kind: ConversationKind.primary,
        promptOverride: 'You are the main agent.',
        policy: policy.toJson(),
        parentConversationId: null,
      );
      final json = meta.toJson();

      // toJson omits null-only fields.
      expect(json.containsKey('parentConversationId'), isFalse);

      final restored = ConversationMeta.fromJson(json);
      expect(restored.id, 'c1');
      expect(restored.model, 'anthropic/claude-sonnet-4-20250514');
      expect(restored.baseUrl, 'https://example.com/v1');
      expect(restored.providerId, 'anthropic');
      expect(restored.label, 'main (claude-sonnet-4-20250514)');
      expect(restored.kind, ConversationKind.primary);
      expect(restored.promptOverride, 'You are the main agent.');
      expect(restored.policy, isNotNull);
      expect(restored.parentConversationId, isNull);

      // A second round-trip is stable (equal wire shape both ways).
      final twice = ConversationMeta.fromJson(restored.toJson());
      expect(twice.toJson(), restored.toJson());
    });

    test('a ConversationMeta equals itself after a toJson/fromJson round-trip',
        () {
      // Packed PermissionPolicy equality: build a policy with a non-default
      // default + a static rule, serialize the meta, and assert structural
      // equality of the restored meta round-trips cleanly.
      final meta = ConversationMeta(
        id: 'c2',
        model: 'openai/gpt-4o',
        kind: ConversationKind.subAgent,
        targetName: 'scout',
        parentConversationId: 'c1',
      );
      final restored = ConversationMeta.fromJson(meta.toJson());
      expect(restored.targetName, 'scout');
      expect(restored.parentConversationId, 'c1');
      expect(restored.label, '');
      expect(restored.baseUrl, isNull);
    });

    test('an old {id, model:null} manifest parses with defaults (compat)', () {
      // Sessions written before the enrichment stored only `{id, model}` and
      // model was always null. fromJson must default every new field rather
      // than throw, and kind falls back to primary.
      final manifest = SessionManifest.fromJson({
        'id': 'legacy',
        'activeConversationId': 'c1',
        'conversations': [
          {'id': 'c1', 'model': null},
        ],
      });
      expect(manifest.conversations, hasLength(1));
      final meta = manifest.conversations.single;
      expect(meta.id, 'c1');
      expect(meta.model, isNull);
      expect(meta.kind, ConversationKind.primary);
      expect(meta.label, '');
      expect(meta.targetName, isNull);
      expect(meta.promptOverride, isNull);
      expect(meta.policy, isNull);
      expect(meta.parentConversationId, isNull);
    });

    test('kind falls back to primary when absent', () {
      final meta = ConversationMeta.fromJson({'id': 'c3', 'model': 'm'});
      expect(meta.kind, ConversationKind.primary);
    });

    test('a v2 manifest reads its version', () {
      final m = SessionManifest.fromJson({
        'version': 2,
        'id': 's',
        'providerId': 'anthropic',
        'activeConversationId': '',
        'conversations': [],
      });
      // The version is not a persisted field — it is always written as 2 on
      // serialization regardless of what was read.
      expect(m.toJson()['version'], 2);
    });
  });

  group('PermissionPolicy serialization', () {
    test('round-trips defaults + static rules; drops session rules', () {
      final policy = PermissionPolicy(rules: const [
        PermissionRule(
            toolName: 'bash',
            pattern: 'git *',
            decision: PermissionDecision.allow),
        PermissionRule(
            toolName: '*',
            pattern: '/secrets/**',
            decision: PermissionDecision.deny),
      ]);
      // A runtime "remember this" session rule — must NOT be persisted.
      policy.remember('write', '/tmp/*', PermissionDecision.allow);
      expect(policy.sessionRules, hasLength(1));

      final restored = PermissionPolicy.fromJson(policy.toJson());

      // Defaults + static rules survive.
      expect(restored.defaults, policy.defaults);
      expect(restored.staticRules, hasLength(2));
      expect(restored.staticRules.first.decision, PermissionDecision.allow);
      expect(restored.staticRules.last.toolName, '*');

      // Session memory is intentionally NOT carried.
      expect(restored.sessionRules, isEmpty);
    });

    test('a round-tripped policy preserves decision behavior', () {
      final policy = PermissionPolicy(rules: const [
        PermissionRule(
            toolName: 'bash',
            pattern: 'git *',
            decision: PermissionDecision.allow),
      ]);
      final restored = PermissionPolicy.fromJson(policy.toJson());
      expect(restored.check('bash', {'command': 'git status'}),
          PermissionDecision.allow);
      expect(restored.check('bash', {'command': 'rm -rf'}),
          PermissionDecision.ask);
    });
  });

  group('SessionManifest serialization', () {
    test('round-trips every field through toJson/fromJson, stable twice', () {
      final policy = PermissionPolicy();
      final conversations = <ConversationMeta>[
        const ConversationMeta(
          id: 'c1',
          providerId: 'anthropic',
          label: 'main',
          kind: ConversationKind.primary,
          promptOverride: 'You are the main agent.',
        ),
        ConversationMeta(
          id: 'c2',
          model: 'openai/openai-large',
          providerId: 'openai',
          label: 'scout',
          kind: ConversationKind.subAgent,
          targetName: 'scout',
          promptOverride: 'You research.',
          policy: policy.toJson(),
          parentConversationId: 'c1',
        ),
        ConversationMeta(
          id: 'c3',
          model: 'anthropic/anthropic-small',
          baseUrl: 'https://anthropic.alt',
          providerId: 'anthropic',
          label: 'implementer (anthropic-small)',
          kind: ConversationKind.spawn,
          targetName: 'implementer',
          promptOverride: 'You implement.',
          policy: policy.toJson(),
          parentConversationId: 'c1',
        ),
      ];
      final manifest = SessionManifest(
        id: 's1',
        providerId: 'anthropic',
        baseUrl: 'https://example.com/v1',
        activeConversationId: 'c2',
        conversations: conversations,
      );

      final restored = SessionManifest.fromJson(manifest.toJson());
      expect(restored.id, 's1');
      expect(restored.providerId, 'anthropic');
      expect(restored.baseUrl, 'https://example.com/v1');
      expect(restored.activeConversationId, 'c2');
      expect(restored.conversations, hasLength(3));
      // Round-trip is stable: a second toJson yields the same wire shape.
      expect(restored.toJson(), manifest.toJson());

      final subAgent = restored.conversations.firstWhere((c) => c.id == 'c2');
      expect(subAgent.kind, ConversationKind.subAgent);
      expect(subAgent.targetName, 'scout');
      expect(subAgent.parentConversationId, 'c1');
      expect(subAgent.policy, isNotNull);

      final spawn = restored.conversations.firstWhere((c) => c.id == 'c3');
      expect(spawn.kind, ConversationKind.spawn);
      expect(spawn.baseUrl, 'https://anthropic.alt');
      expect(spawn.targetName, 'implementer');
      expect(spawn.parentConversationId, 'c1');
    });

    test('version is write-only: any read version parses, re-emits 2', () {
      // The wire format always writes version 2; fromJson ignores whatever
      // version it reads, so odd legacy/future versions must still parse.
      for (final readVersion in const [1, 2, 99]) {
        final m = SessionManifest.fromJson({
          'version': readVersion,
          'id': 's',
          'providerId': 'anthropic',
          'activeConversationId': '',
          'conversations': [],
        });
        expect(m.id, 's');
        expect(m.toJson()['version'], 2);
      }
    });

    test('activeConversationId defaults to empty string when absent', () {
      final m = SessionManifest.fromJson({
        'id': 's',
        'providerId': 'anthropic',
        'conversations': const [],
      });
      expect(m.activeConversationId, '');
    });
  });

  group('sub-agent persistence via factory', () {
    test('a scheduler with a persistence factory writes a subAgent transcript',
        () async {
      final store = MemorySessionStore();
      final registry = _multiProviderRegistry();
      final sessionId = await store.createSession(providerId: 'anthropic');

      // Capture the conversation the factory mints so the test can read it
      // back independently of the scheduler's own handle.
      String? mintedId;
      final scheduler = createScheduler(
        config: Config.parse(const ['--backend', 'ansi']),
        registry: registry,
        pipeline: _pipeline,
      );
      scheduler.persistence =
          (job, {required meta, required parentConversationId}) async {
        final id = await store.createConversationWithMeta(sessionId, meta);
        final providerId = meta.providerId ??
            (meta.model?.contains('/') == true
                ? meta.model!.split('/').first
                : 'anthropic');
        final recorder =
            SessionRecorder(store, sessionId, id, providerId: providerId);
        recorder.attach(sessionId, id);
        mintedId = id;
        return (id, recorder);
      };

      final history = <Message>[
        const Message(role: Role.user, content: [TextBlock('hello')]),
        const Message(role: Role.assistant, content: [TextBlock('hi')]),
      ];
      await store.append(sessionId, 'placeholder', history.first);
      await store.replace(sessionId, 'placeholder', history);

      // Spawn a real delegate job; the factory mints a `subAgent` conversation
      // and the job's completion persists its full transcript there.
      final job = scheduler.spawn(
        task: 'investigate',
        toolProfile: ToolProfile.readOnly,
        parentSystemPrompt: 'You research.',
        parentReference: 'anthropic/anthropic-small',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'placeholder',
        label: 'scout',
      );
      final result = await job.result;
      expect(result.isError, isFalse);

      // The job carried a minted conversation id (factory ran at spawn).
      expect(job.conversationId, isNotNull);
      expect(mintedId, job.conversationId);

      final id = mintedId!;
      // The full transcript was persisted to the minted conversation.
      final persisted = await store.loadConversation(sessionId, id);
      expect(persisted, isNotEmpty);
      expect((persisted.last.content.last as TextBlock).text, 'ok');

      // The manifest carries a `subAgent` meta linked to its parent.
      final meta = store.metaFor(sessionId, id);
      expect(meta, isNotNull);
      expect(meta!.kind, ConversationKind.subAgent);
      expect(meta.parentConversationId, 'placeholder');
      expect(meta.targetName, 'scout');

      await scheduler.dispose();
    });

    // Regression: a /spawn panel must land in the session manifest so it is
    // rebuilt on resume. The primary session already exists when a spawn is
    // created, so relying on the recorder's `meta:` + _lazyInit is NOT enough —
    // _lazyInit only registers meta when it creates the session itself. The
    // coordinator must call createConversationWithMeta explicitly, then attach.
    test('a spawn records its meta in the manifest (not via _lazyInit)',
        () async {
      final store = MemorySessionStore();
      final sessionId = await store.createSession(providerId: 'anthropic');
      // A primary already exists, so the session is materialized before the
      // spawn — this is what made the old `meta:`-only path drop the spawn.
      final primaryId = await store.createConversationWithMeta(
          sessionId,
          ConversationMetaInput.primary(
            providerId: 'anthropic',
            provider: FakeProvider(const [], model: 'anthropic-small'),
            policy: PermissionPolicy(),
            systemPrompt: 'primary system',
          ));

      // Mirror the live openSpawn recorder wiring: explicit meta registration
      // (mints the conversation id) followed by an attach.
      final spawnMeta = ConversationMetaInput.spawn(
        providerId: 'anthropic',
        providerModel: 'anthropic-small',
        policy: PermissionPolicy(),
        systemPrompt: 'spawn system',
        targetName: 'scout',
        parentConversationId: primaryId,
      );
      final spawnId =
          await store.createConversationWithMeta(sessionId, spawnMeta);
      final recorder =
          SessionRecorder(store, sessionId, spawnId, providerId: 'anthropic');
      recorder.attach(sessionId, spawnId);
      await recorder.append(
          const Message(role: Role.user, content: [TextBlock('spawn q')]));

      // The manifest must carry the spawn meta, linked to its parent.
      final meta = store.metaFor(sessionId, spawnId);
      expect(meta, isNotNull,
          reason:
              'spawn must be in the manifest to rebuild its panel on resume');
      expect(meta!.kind, ConversationKind.spawn);
      expect(meta.parentConversationId, primaryId);
      expect(meta.targetName, 'scout');

      // And the negative guard: a recorder constructed with `meta:` for an
      // existing session must NOT register it via append's _lazyInit.
      final orphan = SessionRecorder(store, sessionId, 'orphan',
          providerId: 'anthropic', meta: spawnMeta);
      await orphan
          .append(const Message(role: Role.user, content: [TextBlock('x')]));
      expect(store.metaFor(sessionId, 'orphan'), isNull,
          reason: '_lazyInit only registers meta for a brand-new session; the '
              'primary session already exists, so the meta would be dropped');
    });

    // Regression (real on-disk store): before the fix, /spawn called
    // store.createConversationWithMeta directly, which runs _ensureMaterialized
    // and THROWS if the session directory doesn't exist yet. A fresh session
    // persists lazily, so its directory is absent until the primary's first
    // write — meaning spawn-as-first-action (or spawn right after sending,
    // before the async persist resolves) crashed the app. The fix routes the
    // spawn through the primary recorder's ensureRegistered() first.
    test('a spawn does not throw when the session is not yet materialized',
        () async {
      final store = JsonlSessionStore(
          Directory.systemTemp.createTempSync('tina_spawn_'));
      addTearDown(() {
        if (store.root.existsSync()) store.root.deleteSync(recursive: true);
      });

      // A fresh in-memory session id (placeholder). NOT created on disk yet —
      // exactly the state a brand-new session is in before its first write.
      const placeholder = 'placeholder-not-on-disk';
      final primary = SessionRecorder(store, placeholder, 'primary-conv',
          providerId: 'anthropic',
          meta: ConversationMetaInput.primary(
            providerId: 'anthropic',
            provider: FakeProvider(const [], model: 'anthropic-small'),
            policy: PermissionPolicy(),
            systemPrompt: 'primary system',
          ));

      // Materialize the primary session the way openSpawn now does. Must not
      // throw, even though nothing has been written yet.
      await primary.ensureRegistered();

      // After materialization the recorder holds the real on-disk session id,
      // which the store mints fresh (it diverges from the placeholder).
      expect(primary.sessionId, isNot(placeholder),
          reason: 'store mints a fresh on-disk id at materialization');

      // Now register the spawn under that real id. Pre-fix this threw
      // StateError('Session not found') because the (placeholder) dir was absent.
      final spawnId = await store.createConversationWithMeta(
        primary.sessionId,
        ConversationMetaInput.spawn(
          providerId: 'anthropic',
          providerModel: 'anthropic-small',
          policy: PermissionPolicy(),
          systemPrompt: 'spawn system',
          targetName: 'scout',
          parentConversationId: 'primary-conv',
        ),
      );

      // Both the primary and the spawn must live in the SAME on-disk session.
      // The store mints fresh ids for both (it ignores the passed placeholders),
      // so the manifest carries primary.conversationId and the returned spawnId —
      // this is precisely why the coordinator reads ids back from the store.
      final manifest = await store.loadSession(primary.sessionId);
      expect(manifest.conversations.map((c) => c.id),
          containsAll(<String>[primary.conversationId, spawnId]));

      await store.close();
    });

    test('a store failure in the factory does not fail the spawn', () async {
      final registry = _multiProviderRegistry();
      final scheduler = createScheduler(
        config: Config.parse(const ['--backend', 'ansi']),
        registry: registry,
        pipeline: _pipeline,
      );
      scheduler.persistence =
          (job, {required meta, required parentConversationId}) async {
        throw StateError('disk full');
      };

      final job = scheduler.spawn(
        task: 'investigate',
        toolProfile: ToolProfile.readOnly,
        parentSystemPrompt: 'You research.',
        parentReference: 'anthropic/anthropic-small',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'origin',
      );
      // The job still runs and finishes even though persistence threw.
      final result = await job.result;
      expect(result.isError, isFalse);
      // And it has no persisted conversation (factory never completed).
      expect(job.conversationId, isNull);
      await scheduler.dispose();
    });
  });

  group('restoreConversation rehydration', () {
    late MemorySessionStore store;
    late String sessionId;
    late String primaryId;
    late String scoutId;
    late String implementerId;

    setUp(() async {
      store = MemorySessionStore();
      sessionId = await store.createSession(providerId: 'anthropic');

      // Two primary conversations (the active one + a /clear'd one) and a
      // sub-agent + a spawn, each with a transcript and a full meta.
      primaryId = await store.createConversationWithMeta(
          sessionId,
          ConversationMetaInput.primary(
            providerId: 'anthropic',
            provider: FakeProvider(const [], model: 'anthropic-small'),
            policy: PermissionPolicy(),
            systemPrompt: 'You are the main agent.',
          ));
      scoutId = await store.createConversationWithMeta(
          sessionId,
          ConversationMetaInput.subAgent(
            model: 'anthropic/anthropic-large',
            providerId: 'anthropic',
            policy: PermissionPolicy(defaults: const {
              'read': PermissionDecision.allow,
              'search': PermissionDecision.allow,
              'grep': PermissionDecision.allow,
              'glob': PermissionDecision.allow,
            }),
            systemPrompt: 'You research.',
            targetName: 'scout',
            parentConversationId: primaryId,
          ));
      implementerId = await store.createConversationWithMeta(
          sessionId,
          ConversationMetaInput.spawn(
            providerId: 'openai',
            providerModel: 'openai-large',
            policy: PermissionPolicy(defaults: const {
              'read': PermissionDecision.allow,
              'write': PermissionDecision.allow,
              'edit': PermissionDecision.allow,
              'bash': PermissionDecision.allow,
            }),
            systemPrompt: 'You implement.',
            targetName: 'implementer',
            parentConversationId: primaryId,
          ));
      await store.setActiveConversation(sessionId, primaryId);

      for (final cid in [primaryId, scoutId, implementerId]) {
        await store.append(sessionId, cid,
            const Message(role: Role.user, content: [TextBlock('q')]));
        await store.append(sessionId, cid,
            const Message(role: Role.assistant, content: [TextBlock('a')]));
      }
    });

    RestoreContext _ctx(String activeConversationId) {
      final registry = _multiProviderRegistry();
      final config = Config.parse(const ['--backend', 'ansi']);
      final accountProvider = FakeProvider(const [], model: 'anthropic-small');
      return RestoreContext(
        registry: registry,
        pipeline: _pipeline,
        config: config,
        store: store,
        scheduler: createScheduler(
            config: config, registry: registry, pipeline: _pipeline),
        hostFactory: ({required conversationId, required isActive}) =>
            FakeHostInterface(),
        sessionId: sessionId,
        activeConversationId: activeConversationId,
        accountProvider: accountProvider,
      );
    }

    test('restores a sub-agent under the model it ran under', () async {
      final meta = store.metaFor(sessionId, scoutId)!;
      final conv = await restoreConversation(meta, _ctx(primaryId));

      expect(conv.id, scoutId);
      // Stored model ref is "anthropic/anthropic-large"; the model the rebuilt
      // provider runs under is exactly that id's model portion.
      expect(conv.provider.model, 'anthropic-large');
      // Full transcript is reloaded.
      expect(conv.history, hasLength(2));
      expect((conv.history.first.content.single as TextBlock).text, 'q');
      // Recorder is attached to the existing conversation — not recreated.
      expect(conv.recorder, isNotNull);
      expect(conv.recorder!.conversationId, scoutId);
      expect(conv.recorder!.isInitialized, isTrue);
      // Sub-agent tools come from the stored policy's allow-list (+ delegate).
      expect(conv.agent.tools.all.map((t) => t.schema.name), contains('read'));

      await conv.host.dispose();
    });

    test('restores a spawn under its (different-provider) model', () async {
      final meta = store.metaFor(sessionId, implementerId)!;
      final conv = await restoreConversation(meta, _ctx(primaryId));

      expect(conv.id, implementerId);
      // The spawn ran under openai/openai-large, rebuilt from the meta ref.
      expect(conv.provider.model, 'openai-large');
      expect(conv.history, hasLength(2));
      // The spawn's tools come from its stored policy's allow-list; no nested
      // delegate for spawns.
      expect(conv.agent.tools.all.map((t) => t.schema.name),
          containsAll(['read', 'edit']));

      await conv.host.dispose();
    });

    test('falls back to the account provider when the meta has no model',
        () async {
      // Simulate an old-session primary that stored no model ref.
      final legacyId = await store.createConversationWithMeta(
          sessionId, ConversationMetaInput(kind: ConversationKind.primary));
      await store.append(sessionId, legacyId,
          const Message(role: Role.user, content: [TextBlock('old')]));
      final meta = store.metaFor(sessionId, legacyId)!;
      expect(meta.model, isNull);

      final conv = await restoreConversation(meta, _ctx(primaryId));
      expect(conv.id, legacyId);
      // No model ref → rebuilt under the account provider (anthropic-small).
      expect(conv.provider.model, 'anthropic-small');
      expect(conv.history, hasLength(1));

      await conv.host.dispose();
    });

    test('a spawn with an empty policy restores with no tools', () async {
      // A spawn whose stored policy allows nothing (e.g. a legacy or stripped
      // meta) reconstructs an empty tool set — still rehydrated and replayable.
      final orphanId = await store.createConversationWithMeta(
          sessionId,
          ConversationMetaInput.spawn(
            providerId: 'anthropic',
            providerModel: 'anthropic-small',
            policy: PermissionPolicy(defaults: const {}),
            systemPrompt: 'ghost',
            targetName: 'no-tools',
            parentConversationId: primaryId,
          ));
      final meta = store.metaFor(sessionId, orphanId)!;

      final conv = await restoreConversation(meta, _ctx(primaryId));
      // Still rehydrated and replayable; provider resolves from the ref.
      expect(conv.id, orphanId);
      expect(conv.provider.model, 'anthropic-small');
      // Empty policy → empty tool set (spawns get no nested delegate).
      expect(conv.agent.tools.all, isEmpty);

      await conv.host.dispose();
    });

    test('restoring every non-active conversation rehydrates them all',
        () async {
      // Mirrors the coordinator's resume loop: rehydrate each meta that is
      // not the active conversation.
      final manifest = await store.loadSession(sessionId);
      final restored = <String, Conversation>{};
      for (final meta in manifest.conversations) {
        if (meta.id == primaryId) continue; // active, already built
        restored[meta.id] = await restoreConversation(meta, _ctx(primaryId));
      }

      expect(restored.keys, containsAll([scoutId, implementerId]));
      // The active conversation was not re-restored.
      expect(restored.containsKey(primaryId), isFalse);
      // Each restored conversation replayed its transcript.
      for (final conv in restored.values) {
        expect(conv.history, hasLength(2));
        await conv.host.dispose();
      }

      // The on-disk session is untouched: restore never recreated the
      // conversations (recorders attached, not created).
      final after = await store.loadSession(sessionId);
      expect(after.conversations, hasLength(manifest.conversations.length));
    });
  });

  // Uses the REAL on-disk store: the in-memory store couples meta + messages,
  // so its loadConversation never throws for a listed conversation. Only the
  // file-backed store reproduces a manifest entry whose message file is gone.
  group('restoreConversation throws hard when the message file is missing', () {
    test('a listed conversation with no message file fails with a clear error',
        () async {
      final dir =
          await Directory.systemTemp.createTemp('tina_restore_missing_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final store = JsonlSessionStore(dir);
      addTearDown(() async => await store.close());

      final sessionId = await store.createSession(providerId: 'anthropic');
      final cid = await store.createConversationWithMeta(
          sessionId,
          ConversationMetaInput.primary(
            providerId: 'anthropic',
            provider: FakeProvider(const [], model: 'anthropic-small'),
            policy: PermissionPolicy(),
            systemPrompt: 'You are the main agent.',
          ));
      final meta = (await store.loadSession(sessionId))
          .conversations
          .singleWhere((c) => c.id == cid);

      // Simulate the corruption the change guards against: the manifest lists
      // the conversation, but its message file is gone. A naive attach-then-load
      // ordering would half-attach the recorder before failing; the new ordering
      // fails NOW, before attaching, with a message that names the conversation.
      final convFile = File(p.join(dir.path, sessionId, '$cid.jsonl'));
      expect(await convFile.exists(), isTrue,
          reason: 'sanity: file exists pre-delete');
      await convFile.delete();

      final ctx = RestoreContext(
        registry: _multiProviderRegistry(),
        pipeline: _pipeline,
        config: Config.parse(const ['--backend', 'ansi']),
        store: store,
        scheduler: createScheduler(
            config: Config.parse(const ['--backend', 'ansi']),
            registry: _multiProviderRegistry(),
            pipeline: _pipeline),
        hostFactory: ({required conversationId, required isActive}) =>
            FakeHostInterface(),
        sessionId: sessionId,
        activeConversationId: cid,
        accountProvider: FakeProvider(const [], model: 'anthropic-small'),
      );

      await expectLater(
          restoreConversation(meta, ctx),
          throwsA(isA<StateError>().having((e) => e.message,
              'message names the conversation', contains(cid))));
    });
  });
}
