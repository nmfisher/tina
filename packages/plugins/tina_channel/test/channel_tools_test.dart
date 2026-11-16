import 'package:test/test.dart';
import 'package:tina_channel/tina_channel.dart';

void main() {
  late InMemoryChannelStore store;
  late ChannelTools tools;

  setUp(() {
    store = InMemoryChannelStore();
    tools = ChannelTools(store: store, agentName: 'tina-main');
  });

  test('schemas name and require the core fields', () {
    final names = tools.tools.map((t) => t.name).toList();
    expect(names,
        containsAll(['channel_say', 'channel_read', 'channel_status']));
    for (final tool in tools.tools) {
      expect(tool.name, startsWith('channel_'));
      expect(tool.inputSchema['type'], 'object');
    }
  });

  test('say posts, normalizes the channel and self-attributes', () async {
    final result = await tools.execute(
        'channel_say', {'channel': 'Lobby', 'text': 'hello @subagent'});
    expect(result.isError, isFalse);
    expect(result.content, contains('#lobby'));
    expect(result.content, contains('tina-main'));
    final posted = store.read('#lobby').single;
    expect(posted.sender, 'tina-main');
    expect(posted.mentions, ['subagent']);
  });

  test('say validates text and mentions', () async {
    expect(
        (await tools
                .execute('channel_say', {'channel': '#lobby', 'text': ''}))
            .isError,
        isTrue);
    expect(
        (await tools.execute('channel_say',
                {'channel': '#lobby', 'text': 'x' * 4001}))
            .isError,
        isTrue);
    expect(
        (await tools.execute('channel_say', {
          'channel': '#lobby',
          'text': 'hi',
          'mentions': ['a'.padRight(65)]
        }))
            .isError,
        isTrue);
  });

  test('say reply_to must reference a message in the same channel',
      () async {
    final first = await tools
        .execute('channel_say', {'channel': '#lobby', 'text': 'root'});
    final id =
        int.parse(RegExp(r'id (\d+)').firstMatch(first.content)!.group(1)!);
    final reply = await tools.execute('channel_say', {
      'channel': '#lobby',
      'text': 'answer',
      'reply_to': id,
    });
    expect(reply.isError, isFalse);
    final cross = await tools.execute('channel_say', {
      'channel': '#other',
      'text': 'orphan',
      'reply_to': id,
    });
    expect(cross.isError, isTrue);
  });

  test('read returns scrollback with sender, type and presence',
      () async {
    await tools.execute(
        'channel_say', {'channel': '#lobby', 'text': 'one'});
    store.setMember('#lobby', 'subagent', status: 'idle');
    final result = await tools
        .execute('channel_read', {'channel': '#lobby'});
    expect(result.isError, isFalse);
    expect(result.content, contains('tina-main'));
    expect(result.content, contains('* subagent idle'));
    expect(result.content, contains('present: subagent'));
    expect(result.content, contains('message(s)'));
  });

  test('read since accepts a message id or an ISO timestamp', () async {
    final first =
        await tools.execute('channel_say', {'channel': '#lobby', 'text': '1'});
    final id =
        int.parse(RegExp(r'id (\d+)').firstMatch(first.content)!.group(1)!);
    await tools.execute(
        'channel_say', {'channel': '#lobby', 'text': '2'});
    final byId = await tools.execute(
        'channel_read', {'channel': '#lobby', 'since': id});
    expect(byId.content, contains('after id $id'));
    expect(byId.content, isNot(contains('tina-main 1\n')));
    final byTime = await tools.execute('channel_read', {
      'channel': '#lobby',
      'since': DateTime.now().toUtc().add(const Duration(hours: 1)).toIso8601String()
    });
    expect(byTime.content, contains('0 message(s)'));
  });

  test('read rejects a nonsensical since', () async {
    final result = await tools.execute(
        'channel_read', {'channel': '#lobby', 'since': 'yesterday'});
    expect(result.isError, isTrue);
  });

  test('status sets presence and announces', () async {
    final result = await tools.execute('channel_status', {
      'channel': '#lobby',
      'status': 'working',
      'summary': 'building the store'
    });
    expect(result.isError, isFalse);
    expect(store.members('#lobby').single.status, 'working');
    final status = store.read('#lobby').last;
    expect(status.type, ChannelMessageType.status);
    expect(status.text, contains('building the store'));
  });

  test('status rejects unknown states and long summaries', () async {
    expect(
        (await tools.execute('channel_status',
                {'channel': '#lobby', 'status': 'vibing'}))
            .isError,
        isTrue);
    expect(
        (await tools.execute('channel_status',
                {'channel': '#lobby', 'status': 'done', 'summary': 'x' * 201}))
            .isError,
        isTrue);
  });

  test('unknown tool names error instead of throwing', () async {
    expect((await tools.execute('channel_shout', {})).isError, isTrue);
  });
}
