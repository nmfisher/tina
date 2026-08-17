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

    group('updateSessionUsage (spend persistence)', () {
      test('persists the total and restores it on load', () async {
        final sid = await store.createSession(providerId: 'anthropic');
        expect((await store.loadSession(sid)).usageTokens, 0);

        await store.updateSessionUsage(sid, 1234567);

        final manifest = await store.loadSession(sid);
        expect(manifest.usageTokens, 1234567);
        // Round-trips through the serialized form (usage.tokens).
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
      // And it surfaces on the listed SessionMeta.
      final list = await store.listSessions();
      expect(list.single.cwd, '/home/me/project');
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

    test('list returns metadata sorted newest-first', () async {
      final (olderSid, olderCid) = await newConversation();
      await store.append(olderSid, olderCid,
          const Message(role: Role.user, content: [TextBlock('older first')]));

      // Force a distinct mtime — filesystem timestamp resolution can be coarse.
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

    test('list normalizes whitespace and skips empty text for title', () async {
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

    test('deleteSession removes the session directory', () async {
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

    test('deleteConversation removes one conversation but keeps the session',
        () async {
      final sid = await store.createSession(providerId: 'anthropic');
      final c1 = await store.createConversation(sid);
      final c2 = await store.createConversation(sid);
      await store.deleteConversation(sid, c1);
      expect(() => store.loadConversation(sid, c1), throwsStateError);
      expect(await store.loadConversation(sid, c2), isEmpty);
      final manifest = await store.loadSession(sid);
      expect(manifest.conversations.map((c) => c.id), [c2]);
    });

    test('deleteConversation on the only conversation leaves active empty',
        () async {
      final sid = await store.createSession(providerId: 'anthropic');
      final c1 = await store.createConversation(sid);
      await store.deleteConversation(sid, c1);
      expect(() => store.loadConversation(sid, c1), throwsStateError);
      final manifest = await store.loadSession(sid);
      expect(manifest.conversations, isEmpty);
      expect(manifest.activeConversationId, isEmpty);
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

    test('deleteConversation on a missing session is a no-op', () async {
      await expectLater(
          store.deleteConversation('does-not-exist', 'c1'), completes);
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
        // The store generates canonical IDs on lazy init.
        final r = SessionRecorder(store, 's-placeholder', 'c-placeholder',
            providerId: 'anthropic');
        expect(r.isInitialized, isFalse);

        await r.append(
            const Message(role: Role.user, content: [TextBlock('hello')]));
        expect(r.isInitialized, isTrue);

        // Session and conversation now exist in the store, using the store's
        // generated IDs which the recorder captured.
        final sid = r.sessionId;
        final cid = r.conversationId;
        expect(sid, isNot('s-placeholder'));
        expect(cid, isNot('c-placeholder'));

        final manifest = await store.loadSession(sid);
        expect(manifest.conversations, hasLength(1));
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
}
