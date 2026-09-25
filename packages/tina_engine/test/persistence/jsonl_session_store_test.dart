import 'dart:convert';
import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late JsonlSessionStore store;

  Future<(String, String)> newConversation() async {
    final sid = await store.createSession(providerId: 'anthropic');
    final cid = await store.createConversation(sid);
    return (sid, cid);
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tina_sessions_test_');
    store = JsonlSessionStore(tmp);
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  group('JsonlSessionStore', () {
    test('materializes a legacy session', () async {
      const legacyId = '20240101-120000-abcd';
      final f = File(p.join(tmp.path, '$legacyId.jsonl'));
      await f.create(recursive: true);
      await f.writeAsString(
          '${jsonEncode(const Message(role: Role.user, content: [
            TextBlock('legacy body')
          ]).toJson())}\n');

      final manifest = await store.loadSession(legacyId);
      final cid = manifest.activeConversationId;
      await store.setActiveConversation(legacyId, cid);

      expect(await f.exists(), isFalse);
      expect(await File(p.join(tmp.path, legacyId, 'session.json')).exists(),
          isTrue);
    });

    test('createConversationWithMeta honors a pre-allocated id', () async {
      final sid = await store.createSession(providerId: 'anthropic');
      const pre = '20260924-103234-f0b6';
      final cid = await store.createConversationWithMeta(
          sid, const ConversationMetaInput(label: 'main'),
          conversationId: pre);
      expect(cid, pre,
          reason: 'the UI was already built around the pre-allocated id');
      final manifest = await store.loadSession(sid);
      expect(manifest.conversations.single.id, pre);
      expect(manifest.activeConversationId, pre,
          reason: 'the first conversation becomes active under its real id');
      await store.append(
          sid, pre, const Message(role: Role.user, content: [TextBlock('hi')]));
      expect(
          (await store.loadConversation(sid, pre)).single.content.single,
          isA<TextBlock>().having((t) => t.text, 'text', 'hi'));
    });

    test('a pre-allocated id collision falls back to minting', () async {
      final sid = await store.createSession(providerId: 'anthropic');
      final first = await store.createConversationWithMeta(
          sid, const ConversationMetaInput(),
          conversationId: 'taken');
      final second = await store.createConversationWithMeta(
          sid, const ConversationMetaInput(),
          conversationId: 'taken');
      expect(second, isNot('taken'),
          reason: 'creation must never fail on a collision');
      final ids =
          (await store.loadSession(sid)).conversations.map((c) => c.id);
      expect(ids, containsAll([first, second]));
    });

    test('replace atomically rewrites the conversation file', () async {
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

      final leftovers = await tmp
          .list(recursive: true)
          .where((e) => e.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('cwd defaults to null and is preserved across manifest rewrites',
        () async {
      final sid =
          await store.createSession(providerId: 'anthropic', cwd: '/proj');
      // Each of these rewrites the manifest; cwd must survive.
      await store.createConversationWithMeta(
          sid, const ConversationMetaInput(model: 'anthropic/m'));
      final manifest = await store.loadSession(sid);
      expect(manifest.cwd, '/proj');
      // Old manifests without cwd parse to null.
      final raw = jsonDecode(await File(
              '${tmp.path}${Platform.pathSeparator}$sid${Platform.pathSeparator}session.json')
          .readAsString()) as Map<String, dynamic>;
      raw.remove('cwd');
      await File(
              '${tmp.path}${Platform.pathSeparator}$sid${Platform.pathSeparator}session.json')
          .writeAsString(jsonEncode(raw));
      expect((await store.loadSession(sid)).cwd, isNull);
    });

    test('list on a missing root directory returns empty list', () async {
      final emptyRoot = Directory(
          '${tmp.path}-nope-${DateTime.now().microsecondsSinceEpoch}');
      final s = JsonlSessionStore(emptyRoot);
      expect(await s.listSessions(), isEmpty);
    });

    test('list skips directories without a manifest', () async {
      final sid = await store.createSession(providerId: 'anthropic');
      await store.createConversation(sid);
      // Create an incomplete directory directly under root.
      await Directory(p.join(tmp.path, 'incomplete-dir')).create();

      final list = await store.listSessions();
      expect(list.map((s) => s.id), contains(sid));
      expect(list.map((s) => s.id), isNot(contains('incomplete-dir')));
    });

    test('list skips sessions with a bad manifest', () async {
      final sid = await store.createSession(providerId: 'anthropic');
      await store.createConversation(sid);
      final badSid = 'bad-session';
      await Directory(p.join(tmp.path, badSid)).create();
      await File(p.join(tmp.path, badSid, 'session.json'))
          .writeAsString('not valid json');

      final list = await store.listSessions();
      expect(list.map((s) => s.id), contains(sid));
      expect(list.map((s) => s.id), isNot(contains(badSid)));
    });

    group('description derivation', () {
      Future<SessionMeta> singleMeta() async =>
          (await store.listSessions()).single;

      test('prefers the typed prompt over a synthetic summary continuation',
          () async {
        final (sid, cid) = await newConversation();
        await store.append(
            sid,
            cid,
            const Message(
              role: Role.user,
              isSynthetic: true,
              content: [
                TextBlock('Prior conversation summary:\n\n# Summary\n\nstuff')
              ],
            ));
        await store.append(
            sid,
            cid,
            const Message(
                role: Role.user, content: [TextBlock('fix the resume picker')]));
        final meta = await singleMeta();
        expect(meta.description, 'fix the resume picker');
        // Title skips injected content too when a real prompt exists later.
        expect(meta.title, 'fix the resume picker');
      });

      test('skips tool-result batches before the first typed prompt',
          () async {
        final (sid, cid) = await newConversation();
        await store.append(
            sid,
            cid,
            const Message(role: Role.user, content: [
              ToolResultBlock(toolUseId: 't1', content: 'file contents here')
            ]));
        await store.append(
            sid,
            cid,
            const Message(
                role: Role.user, content: [TextBlock('now make it faster')]));
        expect((await singleMeta()).description, 'now make it faster');
      });

      test('falls back to the first assistant text when nothing was typed',
          () async {
        final (sid, cid) = await newConversation();
        await store.append(
            sid,
            cid,
            const Message(role: Role.assistant, content: [
              TextBlock('Ran the full suite. All 45 tests pass.')
            ]));
        expect((await singleMeta()).description,
            'Ran the full suite. All 45 tests pass.');
      });

      test('empty session has no description', () async {
        await newConversation();
        expect((await singleMeta()).description, isNull);
      });

      test('uses the first line only and truncates long prompts', () async {
        final (sid, cid) = await newConversation();
        await store.append(
            sid,
            cid,
            const Message(
                role: Role.user,
                content: [TextBlock('first line\n\nsecond line')]));
        expect((await singleMeta()).description, 'first line');

        // Derivation stops at the first real prompt, so the truncation case
        // gets its own session; address it by id (list order is by recency).
        final long = 'x' * 200;
        final (longSid, longCid) = await newConversation();
        await store.append(longSid, longCid,
            Message(role: Role.user, content: [TextBlock(long)]));
        final longMeta =
            (await store.listSessions()).firstWhere((m) => m.id == longSid);
        expect(longMeta.description!.length, 121);
        expect(longMeta.description!.endsWith('…'), isTrue);
      });
    });

    test('load skips a corrupt line rather than aborting', () async {
      final (sid, cid) = await newConversation();
      await store.append(sid, cid,
          const Message(role: Role.user, content: [TextBlock('before')]));
      // Splice a non-JSON line into the conversation file.
      await File(p.join(tmp.path, sid, '$cid.jsonl'))
          .writeAsString('this is not json\n', mode: FileMode.append);
      await store.append(sid, cid,
          const Message(role: Role.user, content: [TextBlock('after')]));

      final loaded = await store.loadConversation(sid, cid);
      expect(loaded, hasLength(2));
      expect((loaded.first.content.single as TextBlock).text, 'before');
      expect((loaded.last.content.single as TextBlock).text, 'after');
    });

    test(
        'append after a torn final record does not glue onto it '
        '(tin-g2w9: kill -9 mid-write)', () async {
      final (sid, cid) = await newConversation();
      await store.append(sid, cid,
          const Message(role: Role.user, content: [TextBlock('before')]));
      // A crash mid-append leaves an unterminated, unparseable record.
      await File(p.join(tmp.path, sid, '$cid.jsonl')).writeAsString(
          '{"role":"assistant","content":[{"type":"text","text":"tor',
          mode: FileMode.append);

      await store.append(sid, cid,
          const Message(role: Role.user, content: [TextBlock('after')]));

      // Every remaining line must parse — no glued records, and the message
      // sent after the crash survives the next load.
      final loaded = await store.loadConversation(sid, cid);
      expect(loaded, hasLength(2));
      expect((loaded.first.content.single as TextBlock).text, 'before');
      expect((loaded.last.content.single as TextBlock).text, 'after');
    });

    test('append keeps a complete final record that only lacks its newline',
        () async {
      final (sid, cid) = await newConversation();
      await store.append(sid, cid,
          const Message(role: Role.user, content: [TextBlock('kept')]));
      // Crash between the record bytes and the newline: complete JSON, no \n.
      final f = File(p.join(tmp.path, sid, '$cid.jsonl'));
      final content = await f.readAsString();
      await f.writeAsString(content.substring(0, content.length - 1));

      await store.append(sid, cid,
          const Message(role: Role.user, content: [TextBlock('after')]));

      final loaded = await store.loadConversation(sid, cid);
      expect(loaded, hasLength(2));
      expect((loaded.first.content.single as TextBlock).text, 'kept');
      expect((loaded.last.content.single as TextBlock).text, 'after');
    });

    test('replace cleans up the tempfile when rename fails', () async {
      final (sid, cid) = await newConversation();
      await store.append(sid, cid,
          const Message(role: Role.user, content: [TextBlock('original')]));

      // Force rename failure: replace the target file with a non-empty
      // directory at the same path (POSIX rename onto a non-empty dir fails).
      final targetPath = p.join(tmp.path, sid, '$cid.jsonl');
      await File(targetPath).delete();
      await Directory(targetPath).create();
      await File(p.join(targetPath, 'occupant')).writeAsString('x');

      await expectLater(
        store.replace(sid, cid, const [
          Message(role: Role.user, content: [TextBlock('new')])
        ]),
        throwsA(isA<FileSystemException>()),
      );

      final leftovers = await tmp
          .list(recursive: true)
          .where((e) => e.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test(
        'manifest write is atomic: a failed write leaves the previous '
        'manifest intact and no tempfile behind', () async {
      final sid = await store.createSession(providerId: 'anthropic');
      final cid = await store.createConversation(sid, model: 'm1');

      // Capture the known-good manifest on disk as ground truth.
      final manifestPath = p.join(tmp.path, sid, 'session.json');
      final baseline = File(manifestPath).readAsStringSync();
      final baselineManifest = SessionManifest.fromJson(
          jsonDecode(baseline) as Map<String, dynamic>);

      // Force the next manifest write to fail in the tempfile step: make the
      // tempfile path (session.json.tmp) a directory, so openWrite() throws
      // ("Is a directory") before the rename can ever touch session.json. A
      // non-atomic writeAsString would have truncated session.json here,
      // corrupting the manifest; an atomic tempfile+rename write never reaches
      // the real file, so the previous manifest stays intact.
      final tmpPath = '$manifestPath.tmp';
      await Directory(tmpPath).create();

      await expectLater(
        store.setActiveConversation(sid, cid),
        throwsA(isA<FileSystemException>()),
      );

      // The rename never happened, so the original manifest is untouched...
      expect(File(manifestPath).readAsStringSync(), baseline);
      // ...and loadSession still returns the intact baseline manifest.
      final reloaded = await store.loadSession(sid);
      expect(reloaded.toJson(), baselineManifest.toJson());

      // No tempfile left behind by the cleanup.
      final leftovers = await tmp
          .list(recursive: true)
          .where((e) => e.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty);
    });

    // Regression: the rich per-conversation meta fields (kind, targetName,
    // parentConversationId, promptOverride, policy, providerId, per-conv
    // baseUrl) are only ever verified through the in-memory store in
    // session_restore_test.dart — never through real disk. A toJson/fromJson
    // drift in any of these would be invisible. This test round-trips a full
    // manifest through the real JSONL store and asserts both the reloaded
    // objects AND the raw on-disk session.json as ground truth.
    test("a manifest's full conversation metadata round-trips through disk",
        () async {
      final sid = await store.createSession(
          providerId: 'openai', baseUrl: 'https://example.com/v1');

      // Primary first so it is the live active conversation (first created
      // wins), then a sub-agent and a spawn — each with a full identity meta.
      final primaryId = await store.createConversationWithMeta(
          sid,
          const ConversationMetaInput(
            providerId: 'openai',
            label: 'main (openai-large)',
            kind: ConversationKind.primary,
            promptOverride: 'You are the main agent.',
          ));
      final subAgentId = await store.createConversationWithMeta(
          sid,
          ConversationMetaInput.subAgent(
            model: 'openai/openai-large',
            providerId: 'openai',
            policy: PermissionPolicy(),
            systemPrompt: 'You research.',
            targetName: 'scout',
            parentConversationId: primaryId,
          ));
      final spawnId = await store.createConversationWithMeta(
          sid,
          ConversationMetaInput.spawn(
            providerId: 'anthropic',
            providerModel: 'anthropic-small',
            baseUrl: 'https://anthropic.alt',
            policy: PermissionPolicy(),
            systemPrompt: 'You implement.',
            targetName: 'implementer',
            parentConversationId: primaryId,
          ));

      for (final cid in [primaryId, subAgentId, spawnId]) {
        await store.append(sid, cid,
            const Message(role: Role.user, content: [TextBlock('q')]));
      }

      // --- Reloaded-object assertion: every field survives a loadSession. ---
      final manifest = await store.loadSession(sid);
      expect(manifest.providerId, 'openai');
      expect(manifest.baseUrl, 'https://example.com/v1');
      expect(manifest.activeConversationId, primaryId,
          reason: 'first conversation created is the active one');
      expect(manifest.conversations, hasLength(3));

      final byId = {for (final c in manifest.conversations) c.id: c};
      final primary = byId[primaryId]!;
      expect(primary.kind, ConversationKind.primary);
      expect(primary.providerId, 'openai');
      expect(primary.label, 'main (openai-large)');
      expect(primary.promptOverride, 'You are the main agent.');
      expect(primary.model, isNull);
      expect(primary.baseUrl, isNull);
      expect(primary.targetName, isNull);
      expect(primary.policy, isNull);
      expect(primary.parentConversationId, isNull);

      final subAgent = byId[subAgentId]!;
      expect(subAgent.kind, ConversationKind.subAgent);
      expect(subAgent.model, 'openai/openai-large');
      expect(subAgent.providerId, 'openai');
      expect(subAgent.targetName, 'scout');
      expect(subAgent.parentConversationId, primaryId);
      expect(subAgent.promptOverride, 'You research.');
      expect(subAgent.policy, isNotNull);
      expect(subAgent.baseUrl, isNull);

      final spawn = byId[spawnId]!;
      expect(spawn.kind, ConversationKind.spawn);
      expect(spawn.model, 'anthropic/anthropic-small');
      expect(spawn.providerId, 'anthropic');
      expect(spawn.baseUrl, 'https://anthropic.alt');
      expect(spawn.label, 'implementer (anthropic-small)');
      expect(spawn.targetName, 'implementer');
      expect(spawn.parentConversationId, primaryId);
      expect(spawn.promptOverride, 'You implement.');
      expect(spawn.policy, isNotNull);

      // --- Raw-disk ground truth: read the actual session.json and assert
      // the wire format carries every field (closes the test-gap pattern where
      // in-memory seeds hide a wire-format drift). ---
      final raw = jsonDecode(
              await File(p.join(tmp.path, sid, 'session.json')).readAsString())
          as Map<String, dynamic>;
      expect(raw['version'], 2);
      expect(raw['providerId'], 'openai');
      expect(raw['baseUrl'], 'https://example.com/v1');
      expect(raw['activeConversationId'], primaryId);
      final rawById = {
        for (final c
            in (raw['conversations'] as List).cast<Map<String, dynamic>>())
          c['id'] as String: c
      };
      expect(rawById.keys, containsAll([primaryId, subAgentId, spawnId]));

      expect(rawById[subAgentId]!['kind'], 'subAgent');
      expect(rawById[subAgentId]!['model'], 'openai/openai-large');
      expect(rawById[subAgentId]!['targetName'], 'scout');
      expect(rawById[subAgentId]!['parentConversationId'], primaryId);
      expect(rawById[subAgentId]!['promptOverride'], 'You research.');
      expect(rawById[subAgentId]!['policy'], isNotNull);

      expect(rawById[spawnId]!['kind'], 'spawn');
      expect(rawById[spawnId]!['model'], 'anthropic/anthropic-small');
      expect(rawById[spawnId]!['baseUrl'], 'https://anthropic.alt');
      expect(rawById[spawnId]!['targetName'], 'implementer');
      expect(rawById[spawnId]!['parentConversationId'], primaryId);
      expect(rawById[spawnId]!['promptOverride'], 'You implement.');
      expect(rawById[spawnId]!['policy'], isNotNull);
    });

    test('deleteConversation on a missing conversation file is a no-op',
        () async {
      final sid = await store.createSession(providerId: 'anthropic');
      final c1 = await store.createConversation(sid);
      await File(p.join(tmp.path, sid, '$c1.jsonl')).delete();
      await expectLater(store.deleteConversation(sid, c1), completes);
      final manifest = await store.loadSession(sid);
      expect(manifest.conversations, isEmpty);
      expect(manifest.activeConversationId, isEmpty);
    });

    group('migration from legacy flat files', () {
      test('list reads a legacy flat file in place without migrating',
          () async {
        // Write a legacy single-file session directly under root.
        const legacyId = '20240101-120000-abcd';
        final f = File(p.join(tmp.path, '$legacyId.jsonl'));
        await f.create(recursive: true);
        await f.writeAsString(
            '${jsonEncode(const Message(role: Role.user, content: [
              TextBlock('legacy hello')
            ]).toJson())}\n');

        final list = await store.listSessions();
        expect(list, hasLength(1));
        expect(list.single.id, legacyId);
        expect(list.single.title, contains('legacy hello'));
        expect(list.single.conversationCount, 1);
        expect(list.single.messageCount, 1);

        // Not migrated yet — the directory must not exist.
        expect(await Directory(p.join(tmp.path, legacyId)).exists(), isFalse);
      });

      test('loadSession materializes a legacy file into the nested layout',
          () async {
        const legacyId = '20240101-120000-abcd';
        final f = File(p.join(tmp.path, '$legacyId.jsonl'));
        await f.create(recursive: true);
        await f.writeAsString(
            '${jsonEncode(const Message(role: Role.user, content: [
              TextBlock('legacy body')
            ]).toJson())}\n'
            '${jsonEncode(const Message(role: Role.assistant, content: [
              TextBlock('reply')
            ]).toJson())}\n');

        final manifest = await store.loadSession(legacyId);
        expect(manifest.id, legacyId);
        expect(manifest.conversations, hasLength(1));
        final cid = manifest.activeConversationId;
        expect(cid, isNotEmpty);

        final loaded = await store.loadConversation(legacyId, cid);
        expect(loaded, hasLength(2));

        // The legacy flat file is gone; the nested layout has taken over.
        expect(await f.exists(), isFalse);
        expect(await File(p.join(tmp.path, legacyId, '$cid.jsonl')).exists(),
            isTrue);
        expect(await File(p.join(tmp.path, legacyId, 'session.json')).exists(),
            isTrue);
      });

      test('append materializes a legacy file into the nested layout',
          () async {
        const legacyId = '20240101-120000-abcd';
        final f = File(p.join(tmp.path, '$legacyId.jsonl'));
        await f.create(recursive: true);
        await f.writeAsString(
            '${jsonEncode(const Message(role: Role.user, content: [
              TextBlock('legacy body')
            ]).toJson())}\n');

        // Materialize first (as /resume does), then append to the migrated id.
        final manifest = await store.loadSession(legacyId);
        final cid = manifest.activeConversationId;
        await store.append(legacyId, cid,
            const Message(role: Role.user, content: [TextBlock('new line')]));

        expect(await f.exists(), isFalse);
        final loaded = await store.loadConversation(legacyId, cid);
        expect(loaded, hasLength(2));
        expect((loaded.first.content.single as TextBlock).text, 'legacy body');
        expect((loaded.last.content.single as TextBlock).text, 'new line');
      });

      test('replace materializes a legacy file into the nested layout',
          () async {
        const legacyId = '20240101-120000-abcd';
        final f = File(p.join(tmp.path, '$legacyId.jsonl'));
        await f.create(recursive: true);
        await f.writeAsString(
            '${jsonEncode(const Message(role: Role.user, content: [
              TextBlock('legacy body')
            ]).toJson())}\n');

        final manifest = await store.loadSession(legacyId);
        final cid = manifest.activeConversationId;
        await store.replace(legacyId, cid, const [
          Message(role: Role.user, content: [TextBlock('replaced')]),
        ]);

        expect(await f.exists(), isFalse);
        final loaded = await store.loadConversation(legacyId, cid);
        expect(loaded, hasLength(1));
        expect((loaded.single.content.single as TextBlock).text, 'replaced');
      });
    });

    group('SessionRecorder', () {
      test('lazy-inits the store on first write', () async {
        // Create a recorder with placeholder IDs — no store entries yet.
        // Both ids were pre-allocated by the app: the session id (already
        // surfaced to the user as the resume hint) and the conversation id
        // (already built into every UI panel and log line). Lazy init
        // persists BOTH; minting a replacement conversation id would leave
        // the UI naming a conversation the store never heard of.
        final r = SessionRecorder(store, 's-placeholder', 'c-placeholder',
            providerId: 'anthropic');
        expect(r.isInitialized, isFalse);

        await r.append(
            const Message(role: Role.user, content: [TextBlock('hello')]));
        expect(r.isInitialized, isTrue);

        final sid = r.sessionId;
        final cid = r.conversationId;
        expect(sid, 's-placeholder'); // pre-allocated id honored
        expect(cid, 'c-placeholder'); // pre-allocated id honored

        final manifest = await store.loadSession(sid);
        expect(manifest.conversations, hasLength(1));
        expect(manifest.activeConversationId, 'c-placeholder');
        final loaded = await store.loadConversation(sid, cid);
        expect(loaded, hasLength(1));
      });

      test('setActiveConversation persists after lazy init', () async {
        // Pre-create session + conversations in the store.
        final sid = await store.createSession(providerId: 'anthropic');
        final c1 = await store.createConversation(sid);
        final c2 = await store.createConversation(sid);

        final r = SessionRecorder(store, sid, c1, providerId: 'anthropic');
        // Write a message to trigger lazy init (which loads the existing session).
        await r.append(
            const Message(role: Role.user, content: [TextBlock('hello')]));
        expect(r.isInitialized, isTrue);

        await r.setActiveConversation(c2);
        expect((await store.loadSession(sid)).activeConversationId, c2);
      });

      test('startFresh switches to a new conversation in the same session',
          () async {
        final (sid, cid) = await newConversation();
        final r = SessionRecorder(store, sid, cid, providerId: 'anthropic');
        await r.append(
            const Message(role: Role.user, content: [TextBlock('one')]));

        await r.startFresh();
        expect(r.sessionId, sid, reason: 'session is unchanged');
        expect(r.conversationId, isNot(cid));

        await r.append(
            const Message(role: Role.user, content: [TextBlock('two')]));
        final original = await store.loadConversation(sid, cid);
        final fresh = await store.loadConversation(sid, r.conversationId);
        expect((original.single.content.single as TextBlock).text, 'one');
        expect((fresh.single.content.single as TextBlock).text, 'two');
      });

      test('switchTo points at an existing conversation', () async {
        final (sidA, cidA) = await newConversation();
        await store.append(sidA, cidA,
            const Message(role: Role.user, content: [TextBlock('A')]));
        final sidB = await store.createSession(providerId: 'anthropic');
        final cidB = await store.createConversation(sidB);
        await store.append(sidB, cidB,
            const Message(role: Role.user, content: [TextBlock('B')]));

        final r = SessionRecorder(store, sidA, cidA, providerId: 'anthropic');
        r.switchTo(sidB, cidB);
        await r
            .append(const Message(role: Role.user, content: [TextBlock('B+')]));
        final loaded = await store.loadConversation(sidB, cidB);
        expect(loaded.map((m) => (m.content.single as TextBlock).text),
            ['B', 'B+']);
      });

      test('verifyAttach is false before the recorder is initialized',
          () async {
        final (sid, cid) = await newConversation();
        final r = SessionRecorder(store, sid, cid, providerId: 'anthropic');
        // Never attached and never written — _initialized is false.
        expect(await r.verifyAttach(), isFalse);
      });

      test(
          'verifyAttach is true only when attached to a conversation that is '
          'actually in the on-disk manifest', () async {
        final (sid, cid) = await newConversation();
        final r = SessionRecorder(store, sid, cid, providerId: 'anthropic');

        // Attached to a conversation id that is NOT in the manifest: the meta
        // never listed it, so verifyAttach is false even though attach itself
        // (deliberately) did not enforce it.
        r.attach(sid, 'not-in-manifest');
        expect(await r.verifyAttach(), isFalse);

        // Attached to the real conversation the manifest lists: true.
        r.attach(sid, cid);
        expect(await r.verifyAttach(), isTrue);
        expect(r.sessionId, sid);
        expect(r.conversationId, cid);
      });

      test('verifyAttach is false when the session itself is missing',
          () async {
        final (sid, cid) = await newConversation();
        final r = SessionRecorder(store, sid, cid, providerId: 'anthropic');
        // Attach to a session id that doesn't exist on disk at all.
        r.attach('no-such-session', cid);
        expect(await r.verifyAttach(), isFalse);
      });
    });
  });

  group('project-local transcripts', () {
    late Directory project;

    setUp(() async {
      project = await Directory.systemTemp.createTemp('tina_project_test_');
    });

    tearDown(() async {
      if (await project.exists()) await project.delete(recursive: true);
    });

    Future<(String, String)> newLocalConversation() async {
      final sid = await store.createSession(
          providerId: 'anthropic', cwd: project.path);
      final cid = await store.createConversation(sid);
      return (sid, cid);
    }

    Directory localDir(String sid) =>
        Directory(p.join(project.path, '.tina', 'sessions', sid));

    test('createSession marks the manifest transcriptsLocal', () async {
      final sid = await store.createSession(
          providerId: 'anthropic', cwd: project.path);
      final manifest = await store.loadSession(sid);
      expect(manifest.transcriptsLocal, isTrue);
      // ...and the raw on-disk manifest carries the flag.
      final raw = jsonDecode(
          await File(p.join(tmp.path, sid, 'session.json')).readAsString())
          as Map<String, dynamic>;
      expect(raw['transcriptsLocal'], isTrue);
    });

    test('old manifests without the flag parse as transcriptsLocal false',
        () async {
      final m = SessionManifest.fromJson({
        'id': 's1',
        'activeConversationId': 'c1',
        'conversations': [
          {'id': 'c1'}
        ],
      });
      expect(m.transcriptsLocal, isFalse);
      // False is omitted from the wire form.
      expect(m.toJson().containsKey('transcriptsLocal'), isFalse);
    });

    test('new session writes transcripts to the project-local sidecar',
        () async {
      final (sid, cid) = await newLocalConversation();
      await store.append(
          sid, cid, const Message(role: Role.user, content: [TextBlock('hi')]));

      expect(await File(p.join(localDir(sid).path, '$cid.jsonl')).exists(),
          isTrue);
      // Nothing transcript-shaped under the global session dir.
      expect(await File(p.join(tmp.path, sid, '$cid.jsonl')).exists(), isFalse);
      // The manifest stays global.
      expect(await File(p.join(tmp.path, sid, 'session.json')).exists(),
          isTrue);
    });

    test('loadConversation reads from the project-local sidecar', () async {
      final (sid, cid) = await newLocalConversation();
      await store.append(
          sid, cid, const Message(role: Role.user, content: [TextBlock('hi')]));
      final loaded = await store.loadConversation(sid, cid);
      expect((loaded.single.content.single as TextBlock).text, 'hi');
    });

    test('replace lands in the project-local sidecar', () async {
      final (sid, cid) = await newLocalConversation();
      await store.append(
          sid, cid, const Message(role: Role.user, content: [TextBlock('a')]));
      await store.replace(sid, cid, const [
        Message(role: Role.user, content: [TextBlock('summary')]),
      ]);
      final loaded = await store.loadConversation(sid, cid);
      expect((loaded.single.content.single as TextBlock).text, 'summary');
      expect(await File(p.join(localDir(sid).path, '$cid.jsonl')).exists(),
          isTrue);
    });

    test('sessions without cwd stay in the global layout', () async {
      final sid = await store.createSession(providerId: 'anthropic');
      final cid = await store.createConversation(sid);
      await store.append(
          sid, cid, const Message(role: Role.user, content: [TextBlock('a')]));
      expect(await File(p.join(tmp.path, sid, '$cid.jsonl')).exists(), isTrue);
    });

    test('read falls back to global when the project-local file is missing',
        () async {
      final sid = await store.createSession(
          providerId: 'anthropic', cwd: project.path);
      final cid = await store.createConversation(sid);
      // Simulate the project-local copy vanishing (e.g. not synced): the
      // transcript lives globally only.
      await File(p.join(project.path, '.tina', 'sessions', sid, '$cid.jsonl'))
          .delete();
      await File(p.join(tmp.path, sid, '$cid.jsonl')).writeAsString(
          '${jsonEncode(const Message(role: Role.user, content: [
            TextBlock('global only')
          ]).toJson())}\n');
      final loaded = await store.loadConversation(sid, cid);
      expect((loaded.single.content.single as TextBlock).text, 'global only');
    });

    test('write falls back to global when the recorded cwd was deleted',
        () async {
      final sid = await store.createSession(
          providerId: 'anthropic', cwd: project.path);
      final cid = await store.createConversation(sid);
      await project.delete(recursive: true);
      await store.append(
          sid, cid, const Message(role: Role.user, content: [TextBlock('a')]));
      expect(await File(p.join(tmp.path, sid, '$cid.jsonl')).exists(), isTrue);
    });

    test('listSessions counts and titles from the project-local transcripts',
        () async {
      final (sid, cid) = await newLocalConversation();
      await store.append(sid, cid,
          const Message(role: Role.user, content: [TextBlock('local title')]));
      final list = await store.listSessions();
      final meta = list.singleWhere((s) => s.id == sid);
      expect(meta.messageCount, 1);
      expect(meta.title, 'local title');
      expect(meta.cwd, project.path);
    });

    test('deleteSession cleans up both locations', () async {
      final (sid, cid) = await newLocalConversation();
      await store.append(
          sid, cid, const Message(role: Role.user, content: [TextBlock('a')]));
      expect(await localDir(sid).exists(), isTrue);
      await store.deleteSession(sid);
      expect(await localDir(sid).exists(), isFalse);
      expect(await Directory(p.join(tmp.path, sid)).exists(), isFalse);
    });

    test('deleteConversation removes the project-local file', () async {
      final (sid, cid) = await newLocalConversation();
      await store.append(
          sid, cid, const Message(role: Role.user, content: [TextBlock('a')]));
      await store.deleteConversation(sid, cid);
      expect(await File(p.join(localDir(sid).path, '$cid.jsonl')).exists(),
          isFalse);
      final manifest = await store.loadSession(sid);
      expect(manifest.conversations, isEmpty);
    });

    test('transcriptsLocal survives manifest rewrites', () async {
      final sid = await store.createSession(
          providerId: 'anthropic', cwd: project.path);
      await store.createConversation(sid);
      await store.updateSessionUsage(sid, 42);
      final manifest = await store.loadSession(sid);
      expect(manifest.transcriptsLocal, isTrue);
      expect(manifest.usageTokens, 42);
    });

    test('legacy flat-file migration stays global (never project-local)',
        () async {
      const legacyId = '20240101-120000-abcd';
      final f = File(p.join(tmp.path, '$legacyId.jsonl'));
      await f.create(recursive: true);
      await f.writeAsString(
          '${jsonEncode(const Message(role: Role.user, content: [
            TextBlock('legacy')
          ]).toJson())}\n');

      final manifest = await store.loadSession(legacyId);
      expect(manifest.transcriptsLocal, isFalse);
      final cid = manifest.activeConversationId;
      await store.append(legacyId, cid,
          const Message(role: Role.user, content: [TextBlock('more')]));
      expect(
          await File(p.join(tmp.path, legacyId, '$cid.jsonl')).exists(), isTrue);
    });
  });

  group('SessionManifest provider migration', () {
    test('reads the legacy providerKind key as providerId', () {
      // Manifests written before the registry migration stored the enum name
      // under "providerKind". They must still load.
      final legacy = SessionManifest.fromJson({
        'version': 1,
        'id': 's1',
        'providerKind': 'openai',
        'baseUrl': null,
        'activeConversationId': 'c1',
        'conversations': [
          {'id': 'c1', 'model': 'gpt-4o'}
        ],
      });
      expect(legacy.providerId, 'openai');
      // And round-trip through the new key.
      expect(legacy.toJson()['providerId'], 'openai');
      expect(legacy.toJson().containsKey('providerKind'), isFalse);
    });

    test('defaults to anthropic when neither key is present', () {
      final m = SessionManifest.fromJson({
        'id': 's1',
        'activeConversationId': '',
        'conversations': [],
      });
      expect(m.providerId, 'anthropic');
    });
  });

  group('TimestampedSessionStore (write recency)', () {
    test('reports each conversation\u2019s last-write time in manifest order',
        () async {
      final sid = await store.createSession(providerId: 'anthropic');
      final c1 = await store.createConversation(sid);
      await store.append(sid, c1,
          const Message(role: Role.user, content: [TextBlock('one')]));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final c2 = await store.createConversation(sid);
      await store.append(sid, c2,
          const Message(role: Role.user, content: [TextBlock('two')]));

      final stamps = await store.conversationTimestamps(sid);
      final manifest = await store.loadSession(sid);
      expect(stamps.conversationUpdatedAt, hasLength(2));
      final i1 = manifest.conversations.indexWhere((c) => c.id == c1);
      final i2 = manifest.conversations.indexWhere((c) => c.id == c2);
      expect(
          stamps.conversationUpdatedAt[i2].isAfter(
              stamps.conversationUpdatedAt[i1]),
          isTrue,
          reason: 'c2 was written after c1');
    });

    test('deleted transcript reports epoch, not an error', () async {
      final (sid, cid) = await newConversation();
      await store.append(sid, cid,
          const Message(role: Role.user, content: [TextBlock('x')]));
      final f = File(p.join(tmp.path, sid, '$cid.jsonl'));
      await f.delete();

      final stamps = await store.conversationTimestamps(sid);
      final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
      expect(stamps.conversationUpdatedAt.single, epoch,
          reason: 'a missing transcript reads as never-written, mirroring '
              'loadConversation\u2019s StateError for fallback purposes');
    });

    test('activePointerUpdatedAt tracks deliberate re-points, not transcript '
        'writes', () async {
      final sid = await store.createSession(providerId: 'anthropic');
      final c1 = await store.createConversation(sid);
      final before = await store.activePointerUpdatedAt(sid);
      // Creation rewrites the manifest (first-conversation activation), so
      // the probe is honest only in its RELATIVE ordering:
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await store.append(sid, c1,
          const Message(role: Role.user, content: [TextBlock('grow')]));
      final afterAppend = await store.activePointerUpdatedAt(sid);
      expect(afterAppend, before,
          reason: 'a transcript append must NOT refresh the pointer stamp — '
              'an unrelated manifest write would deaden the staleness guard');

      await Future<void>.delayed(const Duration(milliseconds: 20));
      await store.setActiveConversation(sid, c1);
      final afterRepoint = await store.activePointerUpdatedAt(sid);
      expect(afterRepoint.isAfter(afterAppend), isTrue);
      // Unknown session: epoch, not a throw.
      expect(await store.activePointerUpdatedAt('nope'),
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
    });

    test('conversationTimestamps throws StateError for an unknown session',
        () async {
      await expectLater(
        store.conversationTimestamps('nope'),
        throwsA(isA<StateError>()),
      );
    });
  });
}
