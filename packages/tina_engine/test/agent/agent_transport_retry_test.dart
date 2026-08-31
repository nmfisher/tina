import 'dart:async';
import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_tool.dart';

/// A mid-stream transport failure AFTER content was forwarded, then recovery
/// on the next attempt — the #28 shape: RetryingProvider cannot retry it (its
/// guard only swallows failures that precede any content), so the agent's own
/// turn-level ladder must.
class _MidStreamFailer extends LlmProvider {
  /// One entry per attempt: the events that attempt yields.
  final List<List<StreamEvent>> attempts;

  /// The history each [send] saw, in call order.
  final List<List<Message>> sentHistories = [];
  int calls = 0;

  _MidStreamFailer(this.attempts) : super('midstream-fail');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    sentHistories.add(List<Message>.from(messages));
    if (calls < attempts.length) {
      for (final e in attempts[calls++]) {
        yield e;
      }
    }
  }
}

const _retryable500 = StreamError(
  'GLM 500: upstream internal error',
  statusCode: 500,
);

/// A tool the model may call, allowed without asking.
Tool _echoTool() => FakeTool('echo', (_) => ToolResult('ok'));

Agent _agent(
  LlmProvider provider, {
  required FakeAgentSink sink,
  int transportRetryAttempts = 5,
  Future<void> Function(Duration)? transportBackoffDelay,
}) {
  final a = Agent(
    provider: provider,
    tools: ToolRegistry([_echoTool()]),
    sink: sink,
    policy: PermissionPolicy(defaults: const {
      'echo': PermissionDecision.allow
    }),
    asker: (_) async => PermissionResponse.denyOnce,
    maxSteps: 50,
    system: 'sys',
    transportRetryAttempts: transportRetryAttempts,
    transportBackoffDelay: transportBackoffDelay,
  );
  return a;
}

void main() {
  group('turn-level transport retry (#28)', () {
    test(
        'a retryable mid-stream error is retried in place and the turn '
        'finishes normally', () async {
      final provider = _MidStreamFailer([
        [
          const TextDelta('partial thought'),
          _retryable500,
        ],
        [
          const TextDelta('recovered'),
          const MessageComplete(
            content: [TextBlock('recovered')],
            stopReason: 'end_turn',
          ),
        ],
      ]);
      final sink = FakeAgentSink();
      final delays = <Duration>[];
      final agent = _agent(
        provider,
        sink: sink,
        transportBackoffDelay: (d) async => delays.add(d),
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'hi');

      // The turn FINISHED — not aborted.
      expect(agent.abortedReason, isNull);
      expect(agent.abortedKind, AbortedKind.none);
      // Exactly two real sends (the failure + the re-send).
      expect(provider.calls, 2);
      // The user message appears EXACTLY once in the history — the ladder
      // re-sends from the unchanged history, it does not re-append input.
      final userMessages =
          history.where((m) => m.role == Role.user).toList();
      expect(userMessages, hasLength(1));
      expect(
        (userMessages.single.content.single as TextBlock).text,
        'hi',
      );
      // And the final assistant answer landed after it.
      expect(history.last.role, Role.assistant);
      expect((history.last.content.single as TextBlock).text, 'recovered');
      // The retry notice fired with attempt count, delay, and the error.
      final retryNotices = sink.notices
          .map((n) => n.message)
          .where((m) => m.contains('transport error'))
          .toList();
      expect(retryNotices, hasLength(1));
      expect(retryNotices.single, contains('retry 1/5'));
      expect(retryNotices.single, contains('in 15s'));
      expect(retryNotices.single, contains('500'));
      // First backoff = the 15s ladder start (no Retry-After on the error).
      expect(delays, [const Duration(seconds: 15)]);
    });

    test('the re-send sees the SAME history the failed send saw', () async {
      final provider = _MidStreamFailer([
        [_retryable500],
        [
          const TextDelta('ok'),
          const MessageComplete(
            content: [TextBlock('ok')],
            stopReason: 'end_turn',
          ),
        ],
      ]);
      final agent = _agent(
        provider,
        sink: FakeAgentSink(),
        transportBackoffDelay: (_) async {},
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'same?');

      expect(provider.calls, 2);
      expect(provider.sentHistories, hasLength(2));
      // Byte-identical re-send: the failed step appended nothing, so the
      // second attempt's history equals the first's.
      expect(provider.sentHistories[1].length,
          provider.sentHistories[0].length);
      for (var i = 0; i < provider.sentHistories[0].length; i++) {
        expect(identical(provider.sentHistories[0][i],
            provider.sentHistories[1][i]), isTrue,
            reason: 'message $i must be the same instance — nothing re-added');
      }
    });

    test(
        'a NON-retryable error (401, transient: false) aborts today-style '
        'with AbortedKind.provider and no retry', () async {
      final provider = _MidStreamFailer([
        [
          const TextDelta('partial'),
          const StreamError(
            'GLM 401: bad credentials',
            statusCode: 401,
            transient: false,
          ),
        ],
        [
          const TextDelta('never sent'),
          const MessageComplete(
            content: [TextBlock('never sent')],
            stopReason: 'end_turn',
          ),
        ],
      ]);
      final sink = FakeAgentSink();
      final agent = _agent(
        provider,
        sink: sink,
        transportBackoffDelay: (_) async {},
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'hi');

      expect(provider.calls, 1, reason: '401 must not be re-sent');
      expect(agent.abortedReason, contains('401'));
      expect(agent.abortedKind, AbortedKind.provider);
      // The fatal-error notice, NOT a retry notice.
      expect(
        sink.notices.map((n) => n.message),
        everyElement(isNot(contains('transport error:'))),
      );
      expect(sink.notices.map((n) => n.message),
          anyElement(contains('error:')));
    });

    test(
        'exhausted attempts abort with AbortedKind.transport after exactly '
        'N+1 sends', () async {
      final failer = [
        for (var i = 0; i < 6; i++)
          [
            TextDelta('partial $i'),
            _retryable500,
          ],
      ];
      final provider = _MidStreamFailer(failer);
      final sink = FakeAgentSink();
      final agent = _agent(
        provider,
        sink: sink,
        transportRetryAttempts: 5,
        transportBackoffDelay: (_) async {},
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'hi');

      // 1 original + 5 retries, then the abort.
      expect(provider.calls, 6);
      expect(agent.abortedReason, contains('500'));
      expect(agent.abortedKind, AbortedKind.transport,
          reason: 'transport-retryable AND the ladder is spent');
      // Each retry announced.
      final retries = sink.notices
          .map((n) => n.message)
          .where((m) => m.contains('transport error'))
          .toList();
      expect(retries, hasLength(5));
      expect(retries.first, contains('retry 1/5'));
      expect(retries.last, contains('retry 5/5'));
    });

    test('cancel during the backoff exits the turn cleanly', () async {
      final provider = _MidStreamFailer([
        [_retryable500],
        [
          const TextDelta('must never be sent'),
          const MessageComplete(
            content: [TextBlock('must never be sent')],
            stopReason: 'end_turn',
          ),
        ],
      ]);
      final sink = FakeAgentSink();
      final cancel = Completer<void>();
      // The injectable backoff resolves the cancel mid-wait — ESC arriving
      // during the park.
      final agent = _agent(
        provider,
        sink: sink,
        transportRetryAttempts: 5,
        transportBackoffDelay: (_) async {
          cancel.complete();
        },
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'hi', cancelSignal: cancel.future);

      // No post-cancel send: the ladder stopped, the turn exited cleanly.
      expect(provider.calls, 1);
      expect(agent.abortedKind, AbortedKind.cancel);
      expect(agent.abortedReason, isNull);
      expect(sink.texts, isNot(contains('must never be sent')));
      // The user message was still appended exactly once (write-through keeps
      // everything before the failed step).
      expect(history.where((m) => m.role == Role.user), hasLength(1));
    });

    test('an onError-path error (no metadata) aborts as today', () async {
      // Bare exception on the stream's error channel — no StreamError event,
      // so no classification data reaches the consumer.
      final sink = FakeAgentSink();
      final provider = _ErroringChannelProvider();
      final agent = Agent(
        provider: provider,
        tools: ToolRegistry([_echoTool()]),
        sink: sink,
        policy: PermissionPolicy(defaults: const {
          'echo': PermissionDecision.allow
        }),
        asker: (_) async => PermissionResponse.denyOnce,
        maxSteps: 50,
        system: 'sys',
        transportRetryAttempts: 5,
        transportBackoffDelay: (_) async {},
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'hi');

      expect(agent.abortedReason, contains('socket exploded'));
      expect(agent.abortedKind, AbortedKind.provider,
          reason: 'no streamError metadata — unclassified, never retried');
      expect(provider.calls, 1, reason: 'unclassified errors are not retried');
    });

    test('transportRetryAttempts = 0 preserves the pre-#28 abort', () async {
      final provider = _MidStreamFailer([
        [
          const TextDelta('partial'),
          _retryable500,
        ],
        [
          const TextDelta('never'),
          const MessageComplete(
            content: [TextBlock('never')],
            stopReason: 'end_turn',
          ),
        ],
      ]);
      final sink = FakeAgentSink();
      final agent = _agent(
        provider,
        sink: sink,
        transportRetryAttempts: 0,
        transportBackoffDelay: (_) async {
          fail('no backoff may be scheduled when attempts are 0');
        },
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'hi');

      expect(provider.calls, 1);
      expect(agent.abortedReason, contains('500'));
      expect(agent.abortedKind, AbortedKind.provider,
          reason: 'attempts 0 = the ladder never ran, so the failure is NOT '
              '"retry spent" — the pre-#28 classification stands, which the '
              'sub-agent scheduler maps to transient (a retry may clear it)');
      expect(
        sink.notices.map((n) => n.message),
        everyElement(isNot(contains('transport error:'))),
      );
    });

    test('a server Retry-After overrides the ladder delay, capped at 120s',
        () async {
      // Two ladder cycles in ONE turn: the middle completion asks for a tool
      // (stopReason tool_use) so the step loop continues into a second
      // failure — an end_turn completion would end the turn there.
      final provider = _MidStreamFailer([
        [
          StreamError(
            'GLM 429: slow down',
            statusCode: 429,
            retryAfter: const Duration(seconds: 2),
          ),
        ],
        [
          const MessageComplete(
            content: [
              ToolUseBlock(id: 't1', name: 'echo', input: {'x': 1}),
            ],
            stopReason: 'tool_use',
          ),
        ],
        [
          StreamError(
            'GLM 429: slow down',
            statusCode: 429,
            retryAfter: const Duration(hours: 9),
          ),
        ],
        [
          const TextDelta('done'),
          const MessageComplete(
            content: [TextBlock('done')],
            stopReason: 'end_turn',
          ),
        ],
      ]);
      final sink = FakeAgentSink();
      final delays = <Duration>[];
      final agent = _agent(
        provider,
        sink: sink,
        transportBackoffDelay: (d) async => delays.add(d),
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'hi');

      expect(provider.calls, 4, reason: 'two failures, each recovered');
      expect(agent.abortedReason, isNull);
      // Hint honored; oversized hint capped.
      expect(delays, [
        const Duration(seconds: 2),
        const Duration(seconds: 120),
      ]);
    });

    test('the ladder delay doubles 15s → 30s → 60s → 120s → 120s',
        () async {
      // Pure schedule check through the exported helper.
      expect(transportBackoffFor(1), const Duration(seconds: 15));
      expect(transportBackoffFor(2), const Duration(seconds: 30));
      expect(transportBackoffFor(3), const Duration(seconds: 60));
      expect(transportBackoffFor(4), const Duration(seconds: 120));
      expect(transportBackoffFor(5), const Duration(seconds: 120));
      expect(transportBackoffFor(9), const Duration(seconds: 120),
          reason: 'the ladder saturates at the cap');
      // A retryAfter between 15s and the cap passes through unchanged.
      expect(transportBackoffFor(1, retryAfter: const Duration(seconds: 45)),
          const Duration(seconds: 45));
    });
  });
}

/// A provider that throws on the stream's ERROR channel — the `onError`
/// shape with no StreamError metadata (the consumer's `error` captures the
/// exception but `streamError` stays null).
class _ErroringChannelProvider extends LlmProvider {
  int calls = 0;
  _ErroringChannelProvider() : super('erroring');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    calls++;
    yield const TextDelta('partial');
    throw const SocketException('socket exploded');
  }
}
