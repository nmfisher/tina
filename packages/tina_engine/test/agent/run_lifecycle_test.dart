import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';
import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_provider.dart';

class _Sink extends FakeAgentSink with HostLifecycleAdapter {
  final signals = <bool>[];
  @override
  void setActivity(bool active) => signals.add(active);
}

class _ThrowingObserver extends FakeAgentSink implements RunLifecycleSink {
  int starts = 0, finishes = 0;
  @override
  void runStarted(Object id) {
    starts++;
    throw StateError('start observer');
  }

  @override
  void runCompleted(Object id) {
    finishes++;
    throw StateError('end observer');
  }
}

Agent _agent(LlmProvider provider, AgentSink sink) => Agent(
    provider: provider,
    tools: ToolRegistry([]),
    sink: sink,
    policy: PermissionPolicy(),
    asker: (_) async => PermissionResponse.denyOnce,
    system: '');

class _Pending extends LlmProvider {
  _Pending() : super('pending');
  final started = Completer<void>();
  final stream = StreamController<StreamEvent>();
  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) {
    started.complete();
    return stream.stream;
  }
}

void main() {
  test('one completed run does not clear another run sharing the host',
      () async {
    final sink = _Sink();
    final pending = _Pending();
    final cancel = Completer<void>();
    final first = _agent(pending, sink)
        .run(history: [], userInput: 'first', cancelSignal: cancel.future);
    await pending.started.future;
    await _agent(
            FakeProvider(const [
              [
                MessageComplete(
                    content: [TextBlock('ok')], stopReason: 'end_turn')
              ]
            ]),
            sink)
        .run(history: [], userInput: 'second');
    expect(sink.signals.last, isTrue);
    cancel.complete();
    await first;
    expect(sink.signals.last, isFalse);
  });
  test('observer failures cannot skip execution or completion', () async {
    final sink = _ThrowingObserver();
    final history = <Message>[];
    await _agent(
            FakeProvider(const [
              [
                MessageComplete(
                    content: [TextBlock('ok')], stopReason: 'end_turn')
              ]
            ]),
            sink)
        .run(history: history, userInput: 'hello');
    expect(history.last.role, Role.assistant);
    expect(sink.starts, 1);
    expect(sink.finishes, 1);
  });
  test('outer job activity survives agent completion and completes once',
      () async {
    final sink = _Sink();
    final scope = RunActivity(sink);
    await _agent(
            FakeProvider(const [
              [
                MessageComplete(
                    content: [TextBlock('ok')], stopReason: 'end_turn')
              ]
            ]),
            sink)
        .run(history: [], userInput: 'hello');
    expect(sink.signals.last, isTrue);
    scope.complete();
    scope.complete();
    expect(sink.signals.where((b) => !b), hasLength(1));
  });
  test('provider stream error completes lifecycle', () async {
    final sink = _Sink();
    final provider = _Pending();
    final run = _agent(provider, sink).run(history: [], userInput: 'hello');
    await provider.started.future;
    provider.stream.addError(StateError('provider'));
    unawaited(provider.stream.close());
    await run;
    expect(sink.signals.last, isFalse);
  });
}
