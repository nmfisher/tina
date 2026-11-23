/// Mid-stream stall recovery (commit 32): a stream that already
/// published deltas is no longer terminal on stall — the partial output
/// stands and exactly ONE continuation attempt resumes from where the
/// response left off. One recovery per turn total, shared with the
/// reasoning/output_limit recovery; unpublished stalls keep their
/// existing behavior; cancellation during the retry never re-requests.
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_providers/tina_providers.dart';

final class _RecordingStub extends LlmProvider {
  _RecordingStub(this.reply) : super('stall-stub');
  final Stream<StreamEvent> Function() reply;
  final systems = <String>[];
  var calls = 0;

  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) {
    calls++;
    systems.add(system);
    return reply();
  }

  @override
  void close() {}
}

const _stall = StreamError('stream stalled: no bytes for 0:05:00.00000',
    transient: true, providerCode: 'stream_stalled');

const _done = MessageComplete(
    content: [TextBlock('done')],
    stopReason: 'end_turn',
    usage: TokenUsage(inputTokens: 3, outputTokens: 2));

ProviderPolicyPlugin _policy(_RecordingStub member) {
  final policy = ProviderPolicyPlugin(
      targets: (_) => [ProviderTarget(id: 'only', create: () => member)]);
  addTearDown(policy.closeSession);
  return policy;
}

Future<List<StreamEvent>> _run(LlmProvider provider) =>
    provider.send(system: 'sys', messages: [], tools: const []).toList();

void main() {
  test('a published stall recovers once, continuing from the partial',
      () async {
    late _RecordingStub member;
    member = _RecordingStub(() => Stream.fromIterable(member.calls == 1
        ? [const TextDelta('partial '), _stall]
        : [const TextDelta('rest'), _done]));
    final policy = _policy(member);

    final events = await _run(policy.mainProvider('x'));

    // The partial stands, the notice explains the retry, the second
    // attempt completes — and no content is duplicated.
    expect(events.whereType<TextDelta>().map((d) => d.text).join(),
        'partial rest');
    final notices = events.whereType<StreamNotice>().map((n) => n.text);
    expect(notices, contains(contains('stalled; retrying from where the '
        'response left off')));
    expect(events.whereType<MessageComplete>().single, _done);
    expect(events.whereType<StreamError>(), isEmpty,
        reason: 'the recovery consumed the stall');

    // The continuation instruction rode the system prompt of attempt 2.
    expect(member.calls, 2);
    expect(member.systems.last, contains('stalled mid-stream'));
    expect(member.systems.last, contains('without repeating already-sent '
        'content'));
    expect(member.systems.first, isNot(contains('stalled mid-stream')));
  });

  test('an unpublished stall keeps its existing recovery behavior',
      () async {
    late _RecordingStub member;
    member = _RecordingStub(() => Stream.fromIterable(member.calls == 1
        ? [const ReasoningDelta('thinking'), _stall]
        : [_done]));
    final policy = _policy(member);

    final events = await _run(policy.mainProvider('x'));

    // The pre-existing path: the reasoning-recovery notice, not the
    // stall-continuation one; one retry; attempt 2 completes.
    final notices = events.whereType<StreamNotice>().map((n) => n.text);
    expect(notices, contains(contains('Retrying once before any answer')));
    expect(notices, isNot(contains(contains('retrying from where the'))));
    expect(events.whereType<MessageComplete>().single, _done);
    expect(member.calls, 2);
  });

  test('a second stall in the same turn is terminal', () async {
    late _RecordingStub member;
    member = _RecordingStub(() => Stream.fromIterable(
        [const TextDelta('partial '), _stall]));
    final policy = _policy(member);

    final events = await _run(policy.mainProvider('x'));

    // First stall consumed the one recovery; the second surfaces.
    expect(member.calls, 2);
    final errors = events.whereType<StreamError>();
    expect(errors, hasLength(1));
    expect(errors.single.error, contains('stream stalled'));
    final deltas = events.whereType<TextDelta>().map((d) => d.text).join();
    expect(deltas, contains('partial'),
        reason: 'both attempts published their partial');
  });

  test('a stall recovery never stacks on an output_limit recovery',
      () async {
    late _RecordingStub member;
    member = _RecordingStub(() => Stream.fromIterable(member.calls == 1
        ? [
            const ReasoningDelta('thinking'),
            const StreamError('output limit', providerCode: 'output_limit'),
          ]
        : [const TextDelta('partial '), _stall]));
    final policy = _policy(member);

    final events = await _run(policy.mainProvider('x'));

    // The output_limit recovery fired; the later stall found the
    // budget spent and is terminal — no third request.
    expect(member.calls, 2);
    final errors = events.whereType<StreamError>();
    expect(errors.single.error, contains('stream stalled'));
    expect(events.whereType<StreamNotice>(), isNotEmpty);
  });

  test('cancellation during the retry never re-requests', () async {
    final second = StreamController<StreamEvent>();
    late _RecordingStub member;
    member = _RecordingStub(() => member.calls == 1
        ? Stream.fromIterable([const TextDelta('partial '), _stall])
        : second.stream);
    final policy = _policy(member);

    final provider = policy.mainProvider('x');
    final events = <StreamEvent>[];
    final seenRetry = Completer<void>();
    final subscription = provider
        .send(system: 'sys', messages: [], tools: const [])
        .listen((event) {
      events.add(event);
      if (event is StreamNotice && event.text.contains('retrying from')) {
        if (!seenRetry.isCompleted) seenRetry.complete();
      }
    });

    // Wait for the recovery notice, then cancel before the re-request
    // can start, and settle: a cancelled turn never re-requests —
    // attempt 2 never happens.
    await seenRetry.future.timeout(const Duration(seconds: 5));
    unawaited(subscription.cancel());
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(member.calls, 1,
        reason: 'a cancelled turn never re-requests');
    unawaited(second.close().catchError((Object _) {}));
  });
}
