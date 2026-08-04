import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import 'helpers/fake_agent_sink.dart';

/// A stable, readable description of an [AgentEvent] including its full payload,
/// so tests can assert order + content without value-equality on the event
/// classes (which deliberately don't override `==`).
String _label(AgentEvent e) => switch (e) {
      TextAgentEvent(:final text) => 'text($text)',
      ToolAgentEvent(event: final ToolStartEvent s) =>
        'start(${s.toolName},${s.toolId},${s.input})',
      ToolAgentEvent(event: final ToolOutputEvent o) =>
        'output(${o.toolName},${o.toolId},${o.chunk},stderr=${o.stderr})',
      ToolAgentEvent(event: final ToolCompleteEvent c) =>
        'complete(${c.toolName},${c.toolId},err=${c.isError},${c.result})',
      NoticeAgentEvent(:final message, :final kind) =>
        'notice(${kind.name},$message)',
      JobAgentEvent(:final jobId, :final label, :final event) =>
        'job($jobId,$label,${_label(event)})',
    };

void main() {
  group('AgentEventBus + BusSink', () {
    test('fans sink calls out to subscribers as ordered AgentEvents', () async {
      final bus = AgentEventBus();
      final received = <AgentEvent>[];
      final sub = bus.events.listen(received.add);

      final inner = FakeAgentSink();
      final sink = BusSink(inner, bus);

      // Drive every event-bearing method, interleaved with forward-only ones.
      sink
        ..activityStart()
        ..text('hello ')
        ..text('world')
        ..newline()
        ..toolStart(const ToolStartEvent('bash', 't1', {'cmd': 'ls'}))
        ..toolOutput(const ToolOutputEvent('bash', 't1', 'output'))
        ..toolComplete(const ToolCompleteEvent('bash', 't1',
            isError: false, result: 'done'))
        ..notice('[cancelled]', kind: NoticeKind.warning)
        ..activityStop();

      // The broadcast controller delivers on later microtasks; drain them.
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      bus.dispose();

      // Forward-only calls reached the inner sink but emitted nothing on the
      // bus (they're absent from `received`).
      expect(inner.newlines, 1);
      expect(inner.activityStarts, 1);
      expect(inner.activityStops, 1);

      expect(received.map(_label), [
        'text(hello )',
        'text(world)',
        'start(bash,t1,{cmd: ls})',
        'output(bash,t1,output,stderr=false)',
        'complete(bash,t1,err=false,done)',
        'notice(warning,[cancelled])',
      ]);
    });

    test('composes, not replaces: the inner sink still receives every call',
        () async {
      final bus = AgentEventBus();
      final inner = FakeAgentSink();
      final sink = BusSink(inner, bus);

      sink
        ..text('a')
        ..toolStart(const ToolStartEvent('read', 't2', {}))
        ..notice('hi', kind: NoticeKind.error);

      // No subscriber is needed to prove forwarding — the inner sink has it.
      expect(inner.texts, ['a']);
      expect(inner.toolStarts.single.toolName, 'read');
      expect(inner.notices.single, (message: 'hi', kind: NoticeKind.error));
      bus.dispose();
    });

    test('emit after dispose is a silent no-op', () async {
      final bus = AgentEventBus();
      final received = <AgentEvent>[];
      bus.events.listen(received.add);

      bus.dispose();
      bus.emit(TextAgentEvent('dropped'));

      await Future<void>.delayed(Duration.zero);
      expect(received, isEmpty);
    });

    test('a where() subscriber narrows to tool events only', () async {
      final bus = AgentEventBus();
      final tools = <ToolEvent>[];
      final sub = bus.events
          .where((e) => e is ToolAgentEvent)
          .map((e) => (e as ToolAgentEvent).event)
          .listen(tools.add);

      final sink = BusSink(FakeAgentSink(), bus);
      sink
        ..text('prose')
        ..toolStart(const ToolStartEvent('bash', 't1', {}))
        ..notice('note')
        ..toolComplete(const ToolCompleteEvent('bash', 't1',
            isError: true, result: 'err'));

      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      bus.dispose();

      expect(tools, [
        isA<ToolStartEvent>().having((e) => e.toolName, 'toolName', 'bash'),
        isA<ToolCompleteEvent>()
            .having((e) => e.isError, 'isError', true)
            .having((e) => e.result, 'result', 'err'),
      ]);
    });
  });
}
