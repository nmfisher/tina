import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/agent_test_fixtures.dart';
import '../helpers/fake_provider.dart';

void main() {
  final pipeline = defaultTestPipeline;

  SubAgentScheduler sched(ProviderRegistry r) => testScheduler(r, pipeline: pipeline);

  AgentToolContext ctx(SubAgentScheduler scheduler) =>
      testContext(scheduler, pipeline: pipeline);

  test('send opens a channel; receive returns the reply', () async {
    final scheduler = sched(scriptedRegistry({'a': answerEvents('from-a')}));
    final send = SendTool(ctx(scheduler));

    final res = await send.execute({'target': 'explorer', 'text': 'hi'});
    expect(res.isError, isFalse);
    expect(res.content, contains('Opened channel'));

    final job = scheduler.jobsFor('c1').single;
    await job.result;
    final receive = ReceiveTool(scheduler, originConversationId: 'c1');
    expect((await receive.execute({'id': job.id})).content, 'from-a');
    await scheduler.dispose();
  });

  test('send continues a channel; the prior turn is visible to the agent',
      () async {
    final captured = <List<Message>>[];
    final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
      ..register(ProviderDescriptor(
        id: 'a',
        name: 'a',
        authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
        defaultBaseUrl: 'https://a.test',
        builder: (c) => CaptureProvider(captured, const ['ans']),
        models: const {
          'a-model': ModelInfo(
              id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
        },
      ));
    final scheduler = sched(r);
    final send = SendTool(ctx(scheduler));
    final receive = ReceiveTool(scheduler, originConversationId: 'c1');

    // First turn.
    await send.execute({'target': 'a', 'text': 'first request'});
    final job = scheduler.jobsFor('c1').single;
    await job.result;
    expect((await receive.execute({'id': job.id})).content, 'ans');

    // Second turn to the SAME channel id — replays the prior exchange + follow-up.
    final res =
        await send.execute({'target': job.id, 'text': 'second request'});
    expect(res.isError, isFalse);
    expect(res.content, contains('Sent to channel'));
    await job.result; // the result future is minted fresh per turn
    expect((await receive.execute({'id': job.id})).content, 'ans');

    // The second turn's provider saw the first exchange AND the follow-up.
    expect(captured, hasLength(2));
    final wireText = captured[1]
        .expand((m) => m.content)
        .whereType<TextBlock>()
        .map((b) => b.text)
        .toSet();
    expect(wireText, containsAll(['first request', 'ans', 'second request']));
    await scheduler.dispose();
  });

  test('send to a running channel is rejected (one turn at a time)', () async {
    final gate = Completer<void>();
    final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
      ..register(ProviderDescriptor(
        id: 'a',
        name: 'a',
        authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
        defaultBaseUrl: 'https://a.test',
        builder: (c) => HoldProvider(gate: gate.future),
        models: const {
          'a-model': ModelInfo(
              id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
        },
      ));
    final scheduler = sched(r);
    final send = SendTool(ctx(scheduler));

    await send.execute({'target': 'a', 'text': 'hold'});
    final job = scheduler.jobsFor('c1').single;
    await Future<void>.delayed(Duration.zero); // let it start
    final res = await send.execute({'target': job.id, 'text': 'more'});
    expect(res.isError, isTrue);
    expect(res.content, contains('still running'));

    gate.complete();
    await scheduler.dispose();
  });

  test('send with an empty target errors', () async {
    final scheduler = sched(scriptedRegistry({'a': answerEvents('x')}));
    final send = SendTool(ctx(scheduler));
    final res = await send.execute({'target': '', 'text': 'x'});
    expect(res.isError, isTrue);
    expect(res.content, contains('target` is required'));
    await scheduler.dispose();
  });

  test('a non-id target opens a new read-only channel (no catalog lookup)',
      () async {
    final scheduler = sched(scriptedRegistry({'a': answerEvents('x')}));
    final send = SendTool(ctx(scheduler));
    // 'free-form-label' isn't a channel id or a catalog name — it still opens.
    final res = await send.execute({'target': 'free-form-label', 'text': 'go'});
    expect(res.isError, isFalse);
    expect(res.content, contains('Opened channel'));
    await scheduler.dispose();
  });

  test('receive on an unknown id errors', () async {
    final scheduler = sched(scriptedRegistry({'a': answerEvents('x')}));
    final receive = ReceiveTool(scheduler, originConversationId: 'c1');
    final res = await receive.execute({'id': 'ghost'});
    expect(res.isError, isTrue);
    expect(res.content, contains('unknown channel id'));
    await scheduler.dispose();
  });

  test('close drops a channel from the registry', () async {
    final scheduler = sched(scriptedRegistry({'a': answerEvents('x')}));
    final send = SendTool(ctx(scheduler));
    final close = CloseTool(scheduler, originConversationId: 'c1');

    await send.execute({'target': 'a', 'text': 'hi'});
    final job = scheduler.jobsFor('c1').single;
    await job.result;
    await close.execute({'id': job.id});
    expect(scheduler.jobsFor('c1'), isEmpty);
    await scheduler.dispose();
  });
}
