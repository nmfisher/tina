import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

import 'in_memory_session_store.dart';

/// SP5: the backend-neutral persistence contract suite. The same groups and
/// expectations run against every [SessionStore] implementation — JSONL (the
/// shipped backend) and the in-memory fixture — so a contract drift in either
/// direction is caught. Backend-specific behaviors (file layout, atomic-write
/// mechanics, corrupt-file recovery, legacy migration, project-local
/// transcripts) are NOT here; they live in the JSONL test file.
void main() {
  sessionStoreContractSuite(
    'JsonlSessionStore',
    createStore: () async {
      final tmp =
          await Directory.systemTemp.createTemp('tina_contract_jsonl_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      return JsonlSessionStore(tmp);
    },
  );

  sessionStoreContractSuite(
    'InMemorySessionStore',
    createStore: () async => InMemorySessionStore(),
  );
}

/// Registers the shared contract groups for one backend. [label] names the
/// backend in test output.
void sessionStoreContractSuite(
  String label, {
  required Future<SessionStore> Function() createStore,
}) {
  group('$label (persistence contract)', () {
    late SessionStore store;

    setUp(() async {
      store = await createStore();
      await store.close();
      store = await createStore();
    });

    tearDown(() => store.close());

    Future<(String, String)> newConversation() async {
      final sid = await store.createSession(providerId: 'anthropic');
      final cid = await store.createConversation(sid);
      return (sid, cid);
    }

    test('createSession honors a caller-supplied id', () async {
      const pre = '20260820-025935-1462';
      final sid = await store.createSession(
          providerId: 'anthropic', sessionId: pre);
      expect(sid, pre);
      final cid = await store.createConversation(sid);
      await store.append(
          sid, cid, const Message(role: Role.user, content: [TextBlock('hi')]));
      final manifest = await store.loadSession(pre); // resolves, no throw
      expect(manifest.id, pre);
    });

    test('createSession mints a fresh id on a caller-id collision', () async {
      const pre = 'dup';
      final first = await store.createSession(providerId: 'a', sessionId: pre);
      final second = await store.createSession(providerId: 'a', sessionId: pre);
      expect(first, pre);
      expect(second, isNot(pre)); // collision → fresh id, never an overwrite
      await store.createConversation(second); // both sessions are usable
    });

    test('create -> append -> load round-trips messages in order', () async {
      final (sid, cid) = await newConversation();
      expect(sid, isNotEmpty);
      expect(cid, isNotEmpty);

      await store.append(
        sid,
        cid,
        const Message(role: Role.user, content: [TextBlock('first')]),
      );
      await store.append(
        sid,
        cid,
        Message(role: Role.assistant, content: [
          const TextBlock('reading…'),
          const ToolUseBlock(id: 'u1', name: 'read', input: {'filePath': '/x'}),
        ]),
      );
      await store.append(
        sid,
        cid,
        const Message(role: Role.user, content: [
          ToolResultBlock(toolUseId: 'u1', content: 'contents', isError: false),
        ]),
      );

      final loaded = await store.loadConversation(sid, cid);
      expect(loaded, hasLength(3));
      expect(loaded[0].role, Role.user);
      expect((loaded[0].content.single as TextBlock).text, 'first');
      expect(loaded[1].content[1], isA<ToolUseBlock>());
      expect((loaded[2].content.single as ToolResultBlock).content, 'contents');
    });

    test('loadConversation on missing conversation throws StateError',
        () async {
      final sid = await store.createSession(providerId: 'anthropic');
      expect(() => store.loadConversation(sid, 'does-not-exist'),
          throwsStateError);
    });

    test('loadSession on missing session throws StateError', () async {
      expect(() => store.loadSession('does-not-exist'), throwsStateError);
    });

    group('setActiveConversation', () {
      test('persists the active conversation id', () async {
        final sid = await store.createSession(providerId: 'anthropic');
        final c1 = await store.createConversation(sid);
        final c2 = await store.createConversation(sid);
        expect((await store.loadSession(sid)).activeConversationId, c1,
            reason: 'first conversation is active by default');

        await store.setActiveConversation(sid, c2);

        final manifest = await store.loadSession(sid);
        expect(manifest.activeConversationId, c2);
      });

      test('on missing session throws StateError', () async {
        expect(() => store.setActiveConversation('does-not-exist', 'c1'),
            throwsStateError);
      });

      test('on unknown conversation throws StateError', () async {
        final sid = await store.createSession(providerId: 'anthropic');
        await store.createConversation(sid);
        expect(() => store.setActiveConversation(sid, 'does-not-exist'),
            throwsStateError);
      });
    });

    group('updateConversationModel (model-swap persistence)', () {
      test('persists the new model ref + label and keeps the rest of the meta',
          () async {
        final sid = await store.createSession(providerId: 'anthropic');
        final cid = await store.createConversationWithMeta(sid,
            const ConversationMetaInput(
          model: 'anthropic/claude-sonnet-4-6',
          providerId: 'anthropic',
          label: 'claude-sonnet-4-6',
          kind: ConversationKind.primary,
          promptOverride: 'persisted system',
        ));

        await store.updateConversationModel(sid, cid,
            model: 'deepseek/deepseek-chat', label: 'deepseek-chat');

        final meta = (await store.loadSession(sid))
            .conversations
            .firstWhere((c) => c.id == cid);
        expect(meta.model, 'deepseek/deepseek-chat');
        expect(meta.label, 'deepseek-chat');
        expect(meta.providerId, 'deepseek',
            reason: 'providerId follows the new ref prefix');
        // Untouched identity survives the rewrite.
        expect(meta.kind, ConversationKind.primary);
        expect(meta.promptOverride, 'persisted system');
      });

      test('label omitted keeps the stored label', () async {
        final sid = await store.createSession(providerId: 'anthropic');
        final cid = await store.createConversationWithMeta(sid,
            const ConversationMetaInput(
                model: 'anthropic/claude-sonnet-4-6', label: 'kept'));
        await store.updateConversationModel(sid, cid, model: 'glm/glm-5');
        expect(
            (await store.loadSession(sid))
                .conversations
                .firstWhere((c) => c.id == cid)
                .label,
            'kept');
      });

      test('on unknown conversation throws StateError', () async {
        final sid = await store.createSession(providerId: 'anthropic');
        await store.createConversation(sid);
        expect(
            () => store.updateConversationModel(sid, 'does-not-exist',
                model: 'glm/glm-5'),
            throwsStateError);
      });
    });

    group('SessionRecorder.updateModel', () {
      test('rewrites the meta of an attached conversation', () async {
        final sid = await store.createSession(providerId: 'anthropic');
        final cid = await store.createConversationWithMeta(sid,
            const ConversationMetaInput(model: 'anthropic/claude-sonnet-4-6'));
        final rec = SessionRecorder(store, sid, cid, providerId: 'anthropic')
          ..attach(sid, cid);

        await rec.updateModel('deepseek/deepseek-chat', label: 'deepseek');

        expect(
            (await store.loadSession(sid))
                .conversations
                .firstWhere((c) => c.id == cid)
                .model,
            'deepseek/deepseek-chat');
      });

      test('before any write only updates the captured meta', () async {
        final rec = SessionRecorder(store, 's-unknown', 'c-unknown',
            providerId: 'anthropic',
            meta: const ConversationMetaInput(
                model: 'anthropic/claude-sonnet-4-6'));
        await rec.updateModel('glm/glm-5');
        expect(rec.meta!.model, 'glm/glm-5');
      });
    });

    group('updateSessionUsage (spend persistence)', () {
      test('persists the total and restores it on load', () async {
        final sid = await store.createSession(providerId: 'anthropic');
        expect((await store.loadSession(sid)).usageTokens, 0);

        await store.updateSessionUsage(sid, 1234567);

        final manifest = await store.loadSession(sid);
        expect(manifest.usageTokens, 1234567);
        expect(manifest.toJson()['usage'], {'tokens': 1234567});
        expect(
            SessionManifest.fromJson(manifest.toJson()).usageTokens, 1234567);
      });

      test('clamps negative values to 0', () async {
        final sid = await store.createSession(providerId: 'anthropic');
        await store.updateSessionUsage(sid, -5);
        expect((await store.loadSession(sid)).usageTokens, 0);
      });

      test('a fresh manifest serializes without the usage key', () async {
        final sid = await store.createSession(providerId: 'anthropic');
        final json = (await store.loadSession(sid)).toJson();
        expect(json.containsKey('usage'), isFalse);
      });
    });

    test('replace atomically rewrites the conversation', () async {
      final (sid, cid) = await newConversation();
      await store.append(
          sid, cid, const Message(role: Role.user, content: [TextBlock('a')]));
      await store.append(
          sid, cid, const Message(role: Role.user, content: [TextBlock('b')]));
      expect((await store.loadConversation(sid, cid)).length, 2);

      await store.replace(sid, cid, const [
        Message(role: Role.user, content: [TextBlock('summary')]),
        Message(role: Role.assistant, content: [TextBlock('ack')]),
      ]);

      final after = await store.loadConversation(sid, cid);
      expect(after, hasLength(2));
      expect((after.first.content.single as TextBlock).text, 'summary');
      expect((after.last.content.single as TextBlock).text, 'ack');
    });

    test('replace with an empty list clears the conversation', () async {
      final (sid, cid) = await newConversation();
      await store.append(
          sid, cid, const Message(role: Role.user, content: [TextBlock('a')]));
      expect((await store.loadConversation(sid, cid)).length, 1);

      await store.replace(sid, cid, const []);

      expect(await store.loadConversation(sid, cid), isEmpty);
    });

    test('createSession baseUrl round-trips through loadSession', () async {
      final sid = await store.createSession(
          providerId: 'openai', baseUrl: 'https://example.com/v1');
      final manifest = await store.loadSession(sid);
      expect(manifest.providerId, 'openai');
      expect(manifest.baseUrl, 'https://example.com/v1');
    });

    test('createSession cwd round-trips through loadSession and listSessions',
        () async {
      final sid = await store.createSession(
          providerId: 'anthropic', cwd: '/home/me/project');
      final manifest = await store.loadSession(sid);
      expect(manifest.cwd, '/home/me/project');
      final list = await store.listSessions();
      expect(list.single.cwd, '/home/me/project');
    });

    test('cwd survives manifest rewrites', () async {
      final sid =
          await store.createSession(providerId: 'anthropic', cwd: '/proj');
      // Each of these rewrites the manifest; cwd must survive.
      await store.createConversationWithMeta(
          sid, const ConversationMetaInput(model: 'anthropic/m'));
      final manifest = await store.loadSession(sid);
      expect(manifest.cwd, '/proj');
    });

    test('list returns metadata sorted newest-first', () async {
      final (olderSid, olderCid) = await newConversation();
      await store.append(olderSid, olderCid,
          const Message(role: Role.user, content: [TextBlock('older first')]));

      // Force a distinct updatedAt — timestamp resolution can be coarse.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final (newerSid, newerCid) = await newConversation();
      await store.append(newerSid, newerCid,
          const Message(role: Role.user, content: [TextBlock('newer first')]));

      final list = await store.listSessions();
      expect(list, hasLength(2));
      expect(list.first.id, newerSid);
      expect(list.last.id, olderSid);
      expect(list.first.title, contains('newer first'));
      expect(list.first.messageCount, 1);
    });

    test('list yields title from first user TextBlock; long titles truncated',
        () async {
      final (sid, cid) = await newConversation();
      final longText = 'x' * 100;
      await store.append(
          sid, cid, Message(role: Role.user, content: [TextBlock(longText)]));
      final list = await store.listSessions();
      expect(list.single.title.endsWith('…'), isTrue);
      expect(list.single.title.length, lessThanOrEqualTo(61));
    });

    test('list ignores assistant messages and non-text blocks for title',
        () async {
      final (sid, cid) = await newConversation();
      await store.append(
          sid,
          cid,
          Message(role: Role.assistant, content: [
            const TextBlock('hello'),
            const ToolUseBlock(id: 'u1', name: 'read', input: {}),
          ]));
      await store.append(
          sid,
          cid,
          const Message(role: Role.user, content: [
            ToolResultBlock(toolUseId: 'u1', content: 'body', isError: false),
            TextBlock('actual title'),
          ]));
      final list = await store.listSessions();
      expect(list.single.title, 'actual title');
    });

    test('list normalizes whitespace and skips empty text for title',
        () async {
      final (sid, cid) = await newConversation();
      await store.append(
          sid,
          cid,
          const Message(role: Role.user, content: [
            TextBlock('   \n  one\ttwo  \n  three   '),
          ]));
      final list = await store.listSessions();
      expect(list.single.title, 'one two three');
    });

    test('deleteSession removes the session', () async {
      final (sid, cid) = await newConversation();
      await store.append(
          sid, cid, const Message(role: Role.user, content: [TextBlock('hi')]));
      expect((await store.listSessions()).map((s) => s.id), contains(sid));
      await store.deleteSession(sid);
      expect(
          (await store.listSessions()).map((s) => s.id), isNot(contains(sid)));
      expect(() => store.loadConversation(sid, cid), throwsStateError);
    });

    test('deleteSession on a missing id is a no-op (race-safe)', () async {
      await expectLater(store.deleteSession('does-not-exist'), completes);
    });

    test('a session can hold multiple independent conversations', () async {
      final sid = await store.createSession(providerId: 'anthropic');
      final c1 = await store.createConversation(sid, model: 'm1');
      final c2 = await store.createConversation(sid, model: 'm2');
      expect(c1, isNot(c2));

      await store.append(
          sid, c1, const Message(role: Role.user, content: [TextBlock('one')]));
      await store.append(
          sid, c2, const Message(role: Role.user, content: [TextBlock('two')]));

      expect((await store.loadConversation(sid, c1)), hasLength(1));
      expect((await store.loadConversation(sid, c2)), hasLength(1));
      expect(
          ((await store.loadConversation(sid, c1)).single.content.single
                  as TextBlock)
              .text,
          'one');

      final manifest = await store.loadSession(sid);
      expect(manifest.conversations, hasLength(2));
      expect(manifest.conversations.map((c) => c.id), containsAll([c1, c2]));
      expect(manifest.conversations.firstWhere((c) => c.id == c2).model, 'm2');

      final list = await store.listSessions();
      expect(list.single.conversationCount, 2);
      expect(list.single.messageCount, 2, reason: 'sum across conversations');
    });

    group('deleteConversation', () {
      test('removes one conversation but keeps the session', () async {
        final sid = await store.createSession(providerId: 'anthropic');
        final c1 = await store.createConversation(sid);
        final c2 = await store.createConversation(sid);
        await store.append(sid, c1,
            const Message(role: Role.user, content: [TextBlock('one')]));
        await store.append(sid, c2,
            const Message(role: Role.user, content: [TextBlock('two')]));

        await store.deleteConversation(sid, c1);

        expect(() => store.loadConversation(sid, c1), throwsStateError);
        expect((await store.loadConversation(sid, c2)), hasLength(1));
        final manifest = await store.loadSession(sid);
        expect(manifest.conversations.map((c) => c.id), isNot(contains(c1)));
      });

      test('on the only conversation leaves active empty', () async {
        final sid = await store.createSession(providerId: 'anthropic');
        final c1 = await store.createConversation(sid);
        await store.deleteConversation(sid, c1);
        final manifest = await store.loadSession(sid);
        expect(manifest.activeConversationId, isEmpty);
        expect(manifest.conversations, isEmpty);
      });

      test('on a missing conversation is a no-op', () async {
        final sid = await store.createSession(providerId: 'anthropic');
        await expectLater(
            store.deleteConversation(sid, 'does-not-exist'), completes);
      });

      test('on a missing session is a no-op', () async {
        await expectLater(
            store.deleteConversation('does-not-exist', 'c1'), completes);
      });
    });
  });
}
