import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:test/test.dart';

/// Plays one scripted event list, verbatim — no defaults, no queue.
class _EchoProvider implements LlmProvider {
  final List<StreamEvent> events;
  _EchoProvider(this.events);

  @override
  String get model => 'echo';

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    for (final e in events) {
      yield e;
    }
  }

  @override
  void close() {}
}

/// Records every sighting.
class _Recorder {
  final List<WatchEvent> seen = [];
  void onEvent(WatchEvent e) => seen.add(e);
}

void main() {
  final completion = MessageComplete(
    content: [
      TextBlock('done'),
      ToolUseBlock(id: 'tu_1', name: 'write', input: {'filePath': 'x'}),
    ],
    stopReason: 'tool_use',
    usage: TokenUsage(inputTokens: 1, outputTokens: 2),
  );
  final script = <StreamEvent>[
    const TextDelta('hel'),
    const TextDelta('lo'),
    const ReasoningDelta('thinking', startsBlock: true),
    const ReasoningDelta(' more'),
    const ReasoningEnd(),
    const StreamNotice('retrying'),
    const ToolCallStart(id: 'tu_1', name: 'write'),
    completion,
  ];

  // Identity on every event: same instances, same order.
  Future<List<StreamEvent>> collect(Stream<StreamEvent> s) async {
    final got = <StreamEvent>[];
    await for (final e in s) {
      got.add(e);
    }
    return got;
  }

  test('forwards the stream unchanged: identical events, order, instances',
      () async {
    final tee = TeeProvider(_EchoProvider(script),
        sink: (_){},);
    final forwarded = await collect(tee.send(
        system: 'sys', messages: const [], tools: const []));
    expect(forwarded.length, script.length);
    for (var i = 0; i < script.length; i++) {
      expect(identical(forwarded[i], script[i]), isTrue,
          reason: 'event $i is not the same instance');
    }
    expect(forwarded, equals(script));
  });

  test('emits what it saw, in arrival order, to the sink', () async {
    final rec = _Recorder();
    final tee = TeeProvider(_EchoProvider(script), sink: rec.onEvent);
    await collect(tee.send(
        system: 'sys', messages: const [], tools: const []));
    expect(rec.seen, [
      const SawText('hel'),
      const SawText('lo'),
      const SawThinking('thinking', startsBlock: true),
      const SawThinking(' more'),
      const SawThinkingEnd(complete: true),
      const SawNotice('retrying'),
      const SawToolStart(id: 'tu_1', name: 'write'),
      const SawToolEnd(id: 'tu_1', name: 'write'),
      const SawCompletion('tool_use'),
    ]);
  });

  test('a completion with two tool calls ends both, start order preserved',
      () async {
    final two = MessageComplete(
      content: [
        ToolUseBlock(id: 'a', name: 'ls', input: const {}),
        ToolUseBlock(id: 'b', name: 'read', input: const {}),
      ],
      stopReason: 'tool_use',
    );
    final rec = _Recorder();
    final tee = TeeProvider(_EchoProvider([
      const ToolCallStart(id: 'a', name: 'ls'),
      const ToolCallStart(id: 'b', name: 'read'),
      two,
    ]), sink: rec.onEvent);
    await collect(tee.send(
        system: '', messages: const [], tools: const []));
    expect(
      rec.seen.whereType<SawToolEnd>().map((e) => e.id),
      ['a', 'b'],
    );
    expect(rec.seen.last, const SawCompletion('tool_use'));
  });

  test('a stream with no completion reports the completion as null', () async {
    final rec = _Recorder();
    final tee = TeeProvider(_EchoProvider([const TextDelta('half')]),
        sink: rec.onEvent);
    await collect(tee.send(
        system: '', messages: const [], tools: const []));
    expect(rec.seen, [const SawText('half'), const SawCompletion(null)]);
  });

  test('an in-band StreamError yields no completion sighting', () async {
    final rec = _Recorder();
    final tee = TeeProvider(
        _EchoProvider([const TextDelta('x'), StreamError('boom')]),
        sink: rec.onEvent);
    await collect(tee.send(
        system: '', messages: const [], tools: const []));
    expect(rec.seen, [const SawText('x'), const SawCompletion(null)]);
  });

  test('with no sink it is a pass-through: stream still identical', () async {
    final tee = TeeProvider(_EchoProvider(script));
    final forwarded = await collect(tee.send(
        system: 'sys', messages: const [], tools: const []));
    expect(forwarded, equals(script));
  });

  test('a throwing sink never corrupts the stream', () async {
    var calls = 0;
    final tee = TeeProvider(_EchoProvider([const TextDelta('a')]), sink: (e) {
      calls++;
      throw StateError('viewer broke');
    });
    final forwarded = await collect(tee.send(
        system: '', messages: const [], tools: const []));
    expect(forwarded.length, 1);
    expect(forwarded.single, const TextDelta('a'));
    expect(calls, 2); // text sighting + completion sighting, both attempted.
  });

  test('model and close() delegate to the inner provider', () {
    final inner = ScriptedProvider(const []);
    final tee = TeeProvider(inner);
    expect(tee.model, 'scripted');
    expect(inner.callCount, 0);
    tee.close();
  });

  test('the loop still ends the turn normally over a tee', () async {
    final call = ToolUseBlock(id: 't1', name: 'ls', input: const {});
    final loop = AgentLoop(
      provider: TeeProvider(ScriptedProvider([
        scriptedReply('hi', calls: [call]),
        scriptedReply('done'),
      ])),
      plugins: const [],
    );
    final outcome = await loop.runTurn(const Input('hello', id: 'i1'));
    expect(outcome.stopReason, StopReason.complete);
  });
}
