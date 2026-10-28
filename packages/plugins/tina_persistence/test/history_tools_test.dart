import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_mode/tina_mode.dart';
import 'package:tina_persistence/tina_persistence.dart';

void main() {
  late Directory root;
  late Directory workspace;
  late HistoryCatalog catalog;
  late HistoryLocation local;
  late HistoryLocation other;
  late ModePlugin policy;
  late SessionHistoryTools history;
  late StreamApprovalChannel channel;
  late ApprovalsPlugin approvals;
  late List<ApprovalRequest> requests;
  var answer = ApprovalDecision.deny;

  void save(HistoryLocation location, String id, List<Message> messages,
      {String? title, String? at}) {
    File(location.store).parent.createSync(recursive: true);
    final store = SessionStore.open(location.store);
    store.createSession(id, title: title, entries: [
      for (var i = 0; i < messages.length; i++)
        MessageAppendedEntry(turnId: 't', message: messages[i]).withSeq(i),
    ]);
    store.close();
    if (at != null) {
      final db = sqlite3.open(location.store);
      db.execute(
          'UPDATE log_registry SET at = ? WHERE '
          "json_extract(payload, '\$.slice') = ? OR "
          "json_extract(payload, '\$.session_id') = ?",
          [at, id, id]);
      db.close();
    }
  }

  Message user(String text) =>
      Message(role: Role.user, content: [TextBlock(text)]);
  Message assistant(String text) =>
      Message(role: Role.assistant, content: [TextBlock(text)]);

  Future<Map<String, dynamic>> call(String name,
      [Map<String, Object?> input = const {}]) async {
    final result = await history.execute(name, input);
    expect(result.isError, false, reason: result.content);
    return jsonDecode(result.content) as Map<String, dynamic>;
  }

  setUp(() {
    root = Directory(Directory.systemTemp
        .createTempSync('tina-history-')
        .resolveSymbolicLinksSync());
    workspace = Directory('${root.path}/workspace')..createSync();
    final external = Directory('${root.path}/other')..createSync();
    local = HistoryLocation(
        workspace: workspace.path,
        store: '${workspace.path}/.tina/sessions.db');
    other = HistoryLocation(
        workspace: external.path, store: '${external.path}/.tina/sessions.db');
    catalog = HistoryCatalog('${root.path}/state/session-stores');
    channel = StreamApprovalChannel();
    approvals = ApprovalsPlugin(channel: channel);
    policy = ModePlugin(approvals: approvals);
    requests = [];
    answer = ApprovalDecision.deny;
    final sub = channel.requests.listen((request) {
      requests.add(request);
      channel.respond(request.id, answer);
    });
    history = SessionHistoryTools(
        workspace: workspace.path,
        store: local.store,
        policy: policy,
        catalog: catalog)
      ..currentSessionId = 'active';
    addTearDown(() async {
      history.close();
      policy.closeSession();
      approvals.closeSession();
      channel.closeSession();
      await sub.cancel();
      root.deleteSync(recursive: true);
    });
  });

  test('workspace default never discovers or falls back to external histories',
      () async {
    save(local, 'local', [user('local needle')]);
    save(other, 'external', [user('external secret')]);
    catalog.remember(other);
    final result = await call('search_sessions', {'query': 'needle'});
    expect((result['results'] as List).single['session_id'], 'local');
    expect(requests, isEmpty);
    final empty = await call('search_sessions', {'query': 'external secret'});
    expect(empty['results'], isEmpty);
    expect(requests, isEmpty);
    expect(File(local.store).existsSync(), true);
  });

  test('reads referencing sandbox-home paths carry the ephemeral note',
      () async {
    save(local, 'gone', [
      user('review the plan'),
      assistant('Done — written to:\n\n'
          '/Users/nickfisher/.tina/sandbox-homes/session-22055-RZL4TR/'
          'plans/deploy-coolify-readiness-plan.md\n\n(that is this session\'s '
          'writable home)'),
    ]);
    final read = await call('read_session', {'session_id': 'gone'});
    final note = (read['notes'] as List).single as String;
    expect(note, contains('deleted when their session ends'));
    final last = (read['messages'] as List).last as Map<String, dynamic>;
    expect(last['text'], contains('session-22055-RZL4TR'));

    save(local, 'clean', [user('plain conversation, no scratch paths')]);
    final clean = await call('read_session', {'session_id': 'clean'});
    expect(clean.containsKey('notes'), isFalse);
  });

  test(
      'recent activity beats relevance and creation time; pagination is bounded',
      () async {
    save(local, 'old', [user('needle needle needle')]);
    save(local, 'new', [user('one needle')]);
    save(local, 'active', [user('needle current')]);
    var result = await call('search_sessions', {'query': 'NEEDLE', 'limit': 1});
    expect((result['results'] as List).single['session_id'], 'new');
    expect(result['next_offset'], 1);
    result = await call('search_sessions', {'query': 'needle', 'offset': 1});
    expect((result['results'] as List).single['session_id'], 'old');
    final store = SessionStore.open(local.store);
    store.append('old', [
      MessageAppendedEntry(
              turnId: 'resume', message: assistant('resumed recently'))
          .withSeq(1)
    ]);
    store.close();
    result = await call('search_sessions', {'query': 'needle'});
    expect((result['results'] as List).first['session_id'], 'old');
    expect((result['results'] as List).map((r) => r['session_id']),
        ['old', 'new']);
  });

  test(
      'all selectable modes freely search workspace without altering the database',
      () async {
    save(local, 's', [user('hello')]);
    final bytes = File(local.store).readAsBytesSync();
    for (final mode in PermissionMode.values) {
      policy.mode = mode;
      expect((await call('search_sessions'))['results'], hasLength(1));
      expect((await call('read_session', {'session_id': 's'}))['messages'],
          hasLength(1));
    }
    expect(File(local.store).readAsBytesSync(), bytes);
    expect(requests, isEmpty);
  });

  test('global searches require human approval in every ordinary mode',
      () async {
    save(local, 'local', [user('needle')], at: '2026-01-01T00:00:00Z');
    save(other, 'newer-external', [user('needle')], at: '2026-02-01T00:00:00Z');
    catalog.remember(other);
    for (final mode
        in PermissionMode.values.where((m) => m != PermissionMode.yolo)) {
      policy.mode = mode;
      final denied = await history
          .execute('search_sessions', {'scope': 'global', 'query': 'needle'});
      expect(denied.isError, true);
      expect(denied.content, contains('denied'));
      answer = ApprovalDecision.allow;
      final result =
          await call('search_sessions', {'scope': 'global', 'query': 'needle'});
      expect((result['results'] as List).map((r) => r['session_id']),
          ['newer-external', 'local']);
      answer = ApprovalDecision.deny;
    }
    expect(requests, hasLength(8));
    final details = requests.last.details;
    final description = details['description'] as Map;
    expect(description['title'], 'Search saved conversations');
    expect(description['fields']['Query'], 'needle');
    expect(description['fields']['Workspaces'], contains(other.workspace));
    expect(details['permission_scope_description'],
        contains('does not grant file access'));
    expect(
        (details['access_requirements'] as List)
            .any((r) => r['target'] == other.store && r['granted'] == false),
        true);
  });

  test('global pagination selects by time before merging independent stores',
      () async {
    save(other, 'newest', [user('needle')], at: '2026-03-01T00:00:00Z');
    save(other, 'inserted-later', [user('needle')], at: '2026-01-01T00:00:00Z');
    save(local, 'middle', [user('needle')], at: '2026-02-01T00:00:00.000Z');
    catalog.remember(other);
    answer = ApprovalDecision.allow;
    final first = await call(
        'search_sessions', {'scope': 'global', 'query': 'needle', 'limit': 1});
    expect((first['results'] as List).single['session_id'], 'newest');
    final next = await call('search_sessions', {
      'scope': 'global',
      'query': 'needle',
      'limit': 1,
      'offset': first['next_offset']
    });
    expect((next['results'] as List).single['session_id'], 'middle');
    expect(next['has_more'], true);
  });

  test('a shared custom store is searched once and excludes the active session',
      () async {
    final shared = HistoryLocation(
        workspace: workspace.path, store: '${root.path}/shared.db');
    final alias =
        HistoryLocation(workspace: other.workspace, store: shared.store);
    save(shared, 'older', [user('older text')], at: '2026-01-01T00:00:00Z');
    save(shared, 'newer', [user('newer text')], at: '2026-02-01T00:00:00Z');
    save(shared, 'active', [user('current text')], at: '2026-03-01T00:00:00Z');
    catalog.remember(shared);
    catalog.remember(alias);
    history.close();
    history = SessionHistoryTools(
        workspace: workspace.path,
        store: shared.store,
        policy: policy,
        catalog: catalog)
      ..currentSessionId = 'active';
    answer = ApprovalDecision.allowAlways;
    final first =
        await call('search_sessions', {'scope': 'global', 'limit': 1});
    final hit = (first['results'] as List).single;
    expect(hit['session_id'], 'newer');
    expect(hit['store_id'], shared.id);
    expect(hit['workspace'], shared.workspace);
    expect(first['next_offset'], 1);
    expect(requests.single.details['access_requirements'], hasLength(1));
    answer = ApprovalDecision.deny;
    final next = await call('search_sessions', {
      'scope': 'global',
      'limit': 1,
      'offset': first['next_offset'],
    });
    expect((next['results'] as List).single['session_id'], 'older');
    expect(next['has_more'], false);
    expect(next['next_offset'], isNull);
    expect(requests, hasLength(1));
  });

  test(
      'global search deduplicates external stores without hiding other sessions',
      () async {
    save(local, 'active', [user('current text')]);
    save(local, 'local', [user('local text')]);
    save(other, 'active', [user('different session in another store')]);
    save(other, 'external', [user('external text')]);
    final third = Directory('${root.path}/third')..createSync();
    catalog.remember(other);
    catalog
        .remember(HistoryLocation(workspace: third.path, store: other.store));
    answer = ApprovalDecision.allow;
    final result = await call('search_sessions', {'scope': 'global'});
    final hits = result['results'] as List;
    expect(hits.map((hit) => hit['session_id']),
        unorderedEquals(['local', 'active', 'external']));
    expect(hits.where((hit) => hit['session_id'] == 'active').single['snippet'],
        'different session in another store');
    expect(requests.single.details['access_requirements'], hasLength(2));
  });

  test(
      'store registration aliases can read past sessions but not the active one',
      () async {
    save(local, 'active', [user('current text')]);
    save(local, 'past', [user('past text')]);
    final alias =
        HistoryLocation(workspace: other.workspace, store: local.store);
    catalog.remember(alias);
    answer = ApprovalDecision.allow;
    final result = await history.execute(
        'read_session', {'session_id': 'active', 'store_id': alias.id});
    expect(result.isError, true);
    expect(result.content, contains('Use the current conversation'));
    expect(requests, isEmpty);
    final past = await call(
        'read_session', {'session_id': 'past', 'store_id': alias.id});
    expect((past['messages'] as List).single['text'], 'past text');
  });

  test(
      'Remember covers only these histories in this conversation, including reads',
      () async {
    save(local, 'local', [user('hello')]);
    save(other, 'external', [user('hello')]);
    catalog.remember(other);
    answer = ApprovalDecision.allowAlways;
    await call('search_sessions', {'scope': 'global'});
    expect(requests, hasLength(1));
    answer = ApprovalDecision.deny;
    final read = await call(
        'read_session', {'session_id': 'external', 'store_id': other.id});
    expect((read['messages'] as List).single['text'], 'hello');
    await call('search_sessions', {'scope': 'global', 'query': 'hello'});
    expect(requests, hasLength(1));
    final thirdRoot = Directory('${root.path}/third')..createSync();
    final third = HistoryLocation(
        workspace: thirdRoot.path,
        store: '${thirdRoot.path}/.tina/sessions.db');
    save(third, 'third', [user('private')]);
    catalog.remember(third);
    final denied =
        await history.execute('search_sessions', {'scope': 'global'});
    expect(denied.isError, true);
    expect(requests, hasLength(2));
    final fresh = SessionHistoryTools(
        workspace: workspace.path,
        store: local.store,
        policy: policy,
        catalog: catalog);
    final again = await fresh.execute(
        'read_session', {'session_id': 'external', 'store_id': other.id});
    expect(again.isError, true);
    expect(requests, hasLength(3));
    fresh.close();
  });

  test('Allow once search does not authorize a later external transcript read',
      () async {
    save(other, 'external', [user('secret')]);
    catalog.remember(other);
    answer = ApprovalDecision.allow;
    await call('search_sessions', {'scope': 'global'});
    answer = ApprovalDecision.deny;
    final denied = await history.execute(
        'read_session', {'session_id': 'external', 'store_id': other.id});
    expect(denied.isError, true);
    expect(requests, hasLength(2));
    expect(requests.last.operation, 'read session history');
  });

  test(
      'read pages recent messages chronologically, excludes tool/state/synthetic data',
      () async {
    save(local, 's', [
      user('first'),
      assistant('second'),
      const Message(
          role: Role.user,
          content: [ToolResultBlock(toolUseId: 't', content: 'tool-secret')]),
      const Message(
          role: Role.user,
          content: [TextBlock('synthetic-secret')],
          isSynthetic: true),
      user('third'),
      assistant('last'),
    ]);
    final recent = await call('read_session', {'session_id': 's', 'limit': 2});
    expect(
        (recent['messages'] as List).map((m) => m['text']), ['third', 'last']);
    expect(recent['next_before_seq'], 4);
    final older = await call('read_session', {
      'session_id': 's',
      'limit': 2,
      'before_seq': recent['next_before_seq']
    });
    expect(
        (older['messages'] as List).map((m) => m['text']), ['first', 'second']);
    expect(older['next_before_seq'], null);
    expect((await call('search_sessions', {'query': 'secret'}))['results'],
        isEmpty);
  });

  test(
      'literal search includes titles and Unicode; snippets and messages are capped',
      () async {
    save(local, 's', [user('prefix ${'x' * 7000} literal_% 世界 suffix')],
        title: 'Prior architecture');
    final title = await call('search_sessions', {'query': 'architecture'});
    expect((title['results'] as List).single['title'], 'Prior architecture');
    final text = await call('search_sessions', {'query': 'literal_% 世界'});
    final snippet = (text['results'] as List).single['snippet'] as String;
    expect(snippet, contains('literal_% 世界'));
    expect(snippet.length, lessThanOrEqualTo(400));
    final read = await call('read_session', {'session_id': 's'});
    final message = (read['messages'] as List).single;
    expect((message['text'] as String).length, 6000);
    expect(message['text_truncated'], true);
    expect(message['next_text_offset'], 6000);
    final continued = await call('read_session', {
      'session_id': 's',
      'message_seq': message['seq'],
      'text_offset': message['next_text_offset'],
    });
    final tail = (continued['messages'] as List).single;
    expect(tail['text'], endsWith('literal_% 世界 suffix'));
    expect(tail['text_truncated'], false);
    expect(tail['next_text_offset'], null);
  });

  test(
      'custom store outside workspace and symlink aliases cannot skip approval',
      () async {
    save(other, 's', [user('private')]);
    File(local.store).parent.createSync(recursive: true);
    Link(local.store).createSync(other.store);
    final alias = SessionHistoryTools(
        workspace: workspace.path, store: local.store, policy: policy);
    final denied = await alias.execute('search_sessions', {});
    expect(denied.isError, true);
    expect(requests, hasLength(1));
    expect(
        (requests.single.details['access_requirements'] as List)
            .single['workspace'],
        false);
    alias.close();
  });

  test('missing stores are not created; damaged stores report partial results',
      () async {
    expect((await call('search_sessions'))['results'], isEmpty);
    expect(File(local.store).existsSync(), false);
    save(local, 'local', [user('hi')]);
    File(other.store).parent.createSync(recursive: true);
    File(other.store).writeAsStringSync('broken database');
    catalog.remember(other);
    answer = ApprovalDecision.allow;
    final result = await call('search_sessions', {'scope': 'global'});
    expect(result['unavailable_stores'], 1);
    expect(result['results'], hasLength(1));
  });

  test('invalid inputs and arbitrary store paths fail before approval',
      () async {
    for (final input in [
      {'scope': 'all'},
      {'query': 1},
      {'query': 'x' * 501},
      {'limit': 21},
      {'limit': 0},
      {'offset': -1},
      {'offset': 1001},
    ]) {
      expect((await history.execute('search_sessions', input)).isError, true);
    }
    for (final input in [
      <String, Object?>{},
      {'session_id': ''},
      {'session_id': 's', 'store_id': other.store},
      {'session_id': 's', 'store_id': 'a' * 64},
      {'session_id': 's', 'before_seq': -1},
      {'session_id': 's', 'message_seq': -1},
      {'session_id': 's', 'message_seq': 1, 'before_seq': 2},
      {'session_id': 's', 'text_offset': 1},
    ]) {
      expect((await history.execute('read_session', input)).isError, true);
    }
    expect(requests, isEmpty);
  });

  test(
      'persistence mounts both tools and excludes the active session in real turns',
      () async {
    save(local, 'previous', [user('past discussion')]);
    final provider = ScriptedProvider([
      scriptedReply('', calls: [
        const ToolUseBlock(
            id: 'search',
            name: 'search_sessions',
            input: {'query': 'discussion'})
      ]),
      scriptedReply('Found previous discussion'),
    ]);
    final host = Host.start(
        HostConfig(
            workingDirectory: workspace.path,
            providerFactory: (_) => provider,
            plugins: [
              PersistencePlugin(
                  openStore: () => SessionStore.open(local.store),
                  history: history)
            ]),
        sessionId: 'active');
    addTearDown(host.close);
    await host.send('find discussion');
    final result = host.session.loop.log
        .whereType<MessageAppendedEntry>()
        .expand((entry) => entry.message.content)
        .whereType<ToolResultBlock>()
        .single;
    expect(result.isError, false, reason: result.content);
    final data = jsonDecode(result.content) as Map;
    expect((data['results'] as List).single['session_id'], 'previous');
    expect(catalog.read().single.id, local.id);
  });
}
