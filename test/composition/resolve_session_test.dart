import 'dart:io';

import 'package:tina/composition/app_composition.dart';
import 'package:tina/config.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

/// Regression tests for the `--continue` crash (owner bug 2026-08-24):
/// `Bad state: Conversation not found: <sid>/<cid>` at startup. Modern
/// sessions keep transcripts PROJECT-LOCAL (`<cwd>/.tina/sessions/<sid>/`,
/// gitignored) while the manifest lives in the global store — a fresh clone
/// or `git clean` removes every transcript while the manifest survives, and
/// the manifest's `activeConversationId` then names a file that exists
/// nowhere. resolveSession must degrade (fall back to a readable
/// conversation, skip the session, or say why) instead of throwing before
/// the REPL draws.
///
/// Drives the REAL [JsonlSessionStore] over temp directories so the
/// missing-file behavior is the production one, not a memory fake's.
void main() {
  late Directory home;
  late Directory project;
  late JsonlSessionStore store;

  late String originalCwd;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('tina-resolve-home');
    project = await Directory.systemTemp.createTemp('tina-resolve-proj');
    store = JsonlSessionStore(Directory('${home.path}/sessions'));
    // --continue scopes candidates to the sessions' recorded cwd, matching it
    // against the PROCESS cwd — run from inside the fake project or the folder
    // filter finds nothing and every test below would pass vacuously via the
    // fresh-session path.
    originalCwd = Directory.current.path;
    Directory.current = project;
  });

  tearDown(() async {
    Directory.current = originalCwd;
    await home.delete(recursive: true);
    await project.delete(recursive: true);
  });

  final msg = (String t) => Message(role: Role.user, content: [TextBlock(t)]);

  /// Create a session in [project] with one conversation holding [text].
  Future<String> seedSession(String text) async {
    final sid = await store.createSession(
        providerId: 'anthropic', cwd: project.path);
    final cid = await store.createConversation(sid);
    await store.append(sid, cid, msg(text));
    await store.setActiveConversation(sid, cid);
    return sid;
  }

  /// The project-local transcript path for a conversation (where the store
  /// actually put it — transcriptsLocal sessions write under the cwd).
  File transcript(String sid, String cid) =>
      File('${project.path}/.tina/sessions/$sid/$cid.jsonl');

  test('happy path: --continue loads the active conversation', () async {
    final sid = await seedSession('hello');
    final manifest = await store.loadSession(sid);
    final resolved = await resolveSession(
        Config.parse(const ['--continue']), store);
    expect(resolved.sessionId, sid);
    expect(resolved.activeConversationId, manifest.activeConversationId);
    expect(
        resolved.activeHistory
            .any((m) => m.content.any((b) => b is TextBlock && b.text.contains('hello'))),
        isTrue);
  });

  test(
      'CRASH GUARD: transcript deleted (fresh clone / git clean) — --continue '
      'skips the session and starts fresh instead of throwing', () async {
    final sid = await seedSession('gone');
    await transcript(sid, (await store.loadSession(sid)).activeConversationId)
        .delete();

    final resolved = await resolveSession(
        Config.parse(const ['--continue']), store);
    expect(resolved.sessionId, isNot(sid),
        reason: 'the unreadable session is skipped');
    expect(resolved.manifest, isNull,
        reason: 'a fresh session has no manifest');
    expect(resolved.activeHistory, isEmpty);
  });

  test(
      'fallback: active transcript missing but a sibling conversation reads — '
      '--continue resumes the sibling', () async {
    final sid = await seedSession('active-one');
    final cid2 = await store.createConversation(sid);
    await store.append(sid, cid2, msg('sibling-two'));
    await store.setActiveConversation(sid, cid2);
    await transcript(sid, cid2).delete(); // the ACTIVE one is unreadable

    final resolved = await resolveSession(
        Config.parse(const ['--continue']), store);
    expect(resolved.sessionId, sid, reason: 'the session still has a reader');
    expect(resolved.activeConversationId,
        isNot(cid2),
        reason: 'the unreadable active conversation is not picked');
    expect(
        resolved.activeHistory
            .any((m) => m.content.any((b) => b is TextBlock && b.text.contains('active-one'))),
        isTrue,
        reason: 'the readable sibling\'s history loads');
  });

  test('--continue prefers the newest READABLE session when the newest is dead',
      () async {
    // Seed the LIVE one first so the DEAD one ends up newest by updatedAt —
    // the skip must happen in the newest position, not silently via sorting.
    final liveSid = await seedSession('older-but-alive');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final deadSid = await seedSession('newest-but-dead');
    await transcript(deadSid,
            (await store.loadSession(deadSid)).activeConversationId)
        .delete();

    final resolved = await resolveSession(
        Config.parse(const ['--continue']), store);
    expect(resolved.sessionId, liveSid,
        reason: 'the dead newest session is skipped for the live older one');
  });

  test('--resume with a dead session throws a SAYING-WHY error, not a raw id',
      () async {
    final sid = await seedSession('gone');
    await transcript(sid, (await store.loadSession(sid)).activeConversationId)
        .delete();

    await expectLater(
      resolveSession(Config.parse(['--resume', sid]), store),
      throwsA(isA<StateError>().having((e) => e.message, 'message',
          contains('no readable transcript'))),
      reason: 'an explicit --resume must fail loudly with the cause, but '
          'without the raw Conversation-not-found internals',
    );
  });

  test('--resume with a dead ACTIVE conversation falls back to the sibling',
      () async {
    final sid = await seedSession('first');
    final cid2 = await store.createConversation(sid);
    await store.append(sid, cid2, msg('second'));
    await store.setActiveConversation(sid, cid2);
    await transcript(sid, cid2).delete();

    final resolved =
        await resolveSession(Config.parse(['--resume', sid]), store);
    expect(resolved.sessionId, sid);
    expect(resolved.activeConversationId, isNot(cid2));
    expect(
        resolved.activeHistory
            .any((m) => m.content.any((b) => b is TextBlock && b.text.contains('first'))),
        isTrue);
  });
}
