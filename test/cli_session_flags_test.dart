import 'dart:io';

import 'package:tina/composition/app_composition.dart';
import 'package:tina/config.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import 'helpers/memory_session_store.dart';
import 'helpers/test_registry.dart';

void main() {
  group('--list flag', () {
    test('parses --list into listSessions', () {
      final cfg = Config.parse(
        const ['--list'],
        env: const {},
        registry: testRegistry(const {}),
      );
      expect(cfg.listSessions, isTrue);
      expect(cfg.showHelp, isFalse);
      expect(cfg.initConfig, isFalse);
    });

    test('parses -l abbreviation', () {
      final cfg = Config.parse(
        const ['-l'],
        env: const {},
        registry: testRegistry(const {}),
      );
      expect(cfg.listSessions, isTrue);
    });

    test('short-circuits before provider resolution (no API key needed)', () {
      // No provider, no key — would throw without the early return.
      final cfg = Config.parse(
        const ['--list'],
        env: const {},
        registry: testRegistry(const {}),
      );
      expect(cfg.listSessions, isTrue);
      expect(cfg.apiKey, '');
    });

    test('listSessions is false by default', () {
      final cfg = Config.parse(
        const [],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
      );
      expect(cfg.listSessions, isFalse);
    });
  });

  group('--continue flag', () {
    test('parses --continue into continueLatest', () {
      final cfg = Config.parse(
        const ['--continue'],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
      );
      expect(cfg.continueLatest, isTrue);
    });

    test('parses -c abbreviation', () {
      final cfg = Config.parse(
        const ['-c'],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
      );
      expect(cfg.continueLatest, isTrue);
    });

    test('continueLatest is false by default', () {
      final cfg = Config.parse(
        const [],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
      );
      expect(cfg.continueLatest, isFalse);
    });

    test('--resume and --continue are mutually exclusive', () {
      expect(
        () => Config.parse(
          const ['--resume', 'abc', '--continue'],
          env: const {'ANTHROPIC_API_KEY': 'sk'},
          registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
        ),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('mutually exclusive'),
        )),
      );
    });
  });

  group('resolveSession with --continue', () {
    test('picks the most recently updated session', () async {
      final store = MemorySessionStore();
      // Create two sessions; the second is newer.
      final sid1 = await store.createSession(
          providerId: 'anthropic', updatedAt: DateTime(2026, 1, 1));
      final cid1 = await store.createConversation(sid1);
      await store.append(
          sid1, cid1, Message(role: Role.user, content: [TextBlock('old')]));

      final sid2 = await store.createSession(
          providerId: 'anthropic', updatedAt: DateTime(2026, 6, 1));
      final cid2 = await store.createConversation(sid2);
      await store.append(
          sid2, cid2, Message(role: Role.user, content: [TextBlock('recent')]));

      final cfg = Config.parse(
        const ['--continue'],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
      );

      final resolved = await resolveSession(cfg, store);
      expect(resolved.sessionId, sid2);
      expect(resolved.activeConversationId, cid2);
      expect(resolved.activeHistory, hasLength(1));
      expect((resolved.activeHistory.first.content.first as TextBlock).text,
          'recent');
    });

    test('falls back to fresh session when no saved sessions exist', () async {
      final store = MemorySessionStore();
      final cfg = Config.parse(
        const ['--continue'],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
      );

      final resolved = await resolveSession(cfg, store);
      // No saved sessions → fresh start with generated IDs.
      expect(resolved.sessionId, isNotEmpty);
      expect(resolved.activeConversationId, isNotEmpty);
      expect(resolved.activeHistory, isEmpty);
    });

    test('scopes to the current folder (ignores newer sessions elsewhere)',
        () async {
      final here = Directory.current.path;
      final store = MemorySessionStore();
      // A session in THIS folder, older.
      final hereSid = await store.createSession(
          providerId: 'anthropic', cwd: here, updatedAt: DateTime(2026, 1, 1));
      final hereCid = await store.createConversation(hereSid);
      await store.append(hereSid, hereCid,
          Message(role: Role.user, content: [TextBlock('here')]));

      // A session in ANOTHER folder, NEWER — must be ignored.
      final awaySid = await store.createSession(
          providerId: 'anthropic',
          cwd: '/some/other/folder',
          updatedAt: DateTime(2026, 6, 1));
      final awayCid = await store.createConversation(awaySid);
      await store.append(awaySid, awayCid,
          Message(role: Role.user, content: [TextBlock('away')]));

      final cfg = Config.parse(
        const ['--continue'],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
      );

      final resolved = await resolveSession(cfg, store);
      expect(resolved.sessionId, hereSid);
      expect((resolved.activeHistory.first.content.first as TextBlock).text,
          'here');
    });

    test('falls back to fresh when no session matches the current folder',
        () async {
      final store = MemorySessionStore();
      // Only a session in another folder exists.
      final awaySid = await store.createSession(
          providerId: 'anthropic',
          cwd: '/some/other/folder',
          updatedAt: DateTime(2026, 6, 1));
      final awayCid = await store.createConversation(awaySid);
      await store.append(awaySid, awayCid,
          Message(role: Role.user, content: [TextBlock('away')]));

      final cfg = Config.parse(
        const ['--continue'],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
      );

      final resolved = await resolveSession(cfg, store);
      expect(resolved.sessionId, isNot(awaySid));
      expect(resolved.activeHistory, isEmpty);
    });
  });

  group('--force flag', () {
    test('parses --force into forceLock', () {
      final cfg = Config.parse(
        const ['--force'],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
      );
      expect(cfg.forceLock, isTrue);
    });

    test('forceLock is false by default', () {
      final cfg = Config.parse(
        const [],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
      );
      expect(cfg.forceLock, isFalse);
    });
  });

  group('resolveSession with --resume', () {
    test('loads the specified session by id', () async {
      final store = MemorySessionStore();
      final sid = await store.createSession(providerId: 'anthropic');
      final cid = await store.createConversation(sid);
      await store.append(
          sid, cid, Message(role: Role.user, content: [TextBlock('hello')]));

      final cfg = Config.parse(
        ['--resume', sid],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
      );

      final resolved = await resolveSession(cfg, store);
      expect(resolved.sessionId, sid);
      expect(resolved.activeConversationId, cid);
      expect(resolved.activeHistory, hasLength(1));
    });
  });

  group('resolveSession fresh start', () {
    test('generates IDs locally without writing to store', () async {
      final store = MemorySessionStore();
      final cfg = Config.parse(
        const [],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
      );

      final resolved = await resolveSession(cfg, store);
      expect(resolved.sessionId, isNotEmpty);
      expect(resolved.activeConversationId, isNotEmpty);
      expect(resolved.activeHistory, isEmpty);
      // Store was never touched — session not written to disk.
      expect((await store.listSessions()), isEmpty);
    });
  });
}
