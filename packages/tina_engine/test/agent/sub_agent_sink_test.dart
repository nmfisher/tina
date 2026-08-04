import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  test('forwards payload calls onto the bus as tagged JobAgentEvents', () async {
    final bus = AgentEventBus();
    final sink = SubAgentSink(jobId: 'j1', label: 'research', bus: bus);

    final received = <JobAgentEvent>[];
    final sub = bus.events.listen((e) {
      if (e is JobAgentEvent) received.add(e);
    });

    sink.text('looking');
    sink.toolStart(const ToolStartEvent('read', 't1', {'filePath': '/x'}));
    sink.toolComplete(const ToolCompleteEvent('read', 't1',
        isError: false, result: 'file contents'));
    sink.notice('done', kind: NoticeKind.warning);

    // Let the broadcast stream deliver.
    await Future<void>.delayed(Duration.zero);
    sub.cancel();

    expect(received, hasLength(4));
    expect(received.every((e) => e.jobId == 'j1'), isTrue);
    expect(received.every((e) => e.label == 'research'), isTrue);
    expect(received[0].event, isA<TextAgentEvent>());
    expect((received[0].event as TextAgentEvent).text, 'looking');
    expect(received[1].event, isA<ToolAgentEvent>());
    expect(received[3].event, isA<NoticeAgentEvent>());
    expect((received[3].event as NoticeAgentEvent).kind, NoticeKind.warning);
  });

  test('newline and activity signals emit nothing', () async {
    final bus = AgentEventBus();
    final sink = SubAgentSink(jobId: 'j1', label: 'r', bus: bus);

    final count = <int>[];
    final sub = bus.events.listen((_) => count.add(1));
    sink.newline();
    sink.activityStart();
    sink.activityStop();
    await Future<void>.delayed(Duration.zero);
    sub.cancel();

    expect(count, isEmpty);
  });
}
