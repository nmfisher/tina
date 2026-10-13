import 'dart:async';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

final class _Tool extends AgentPlugin {
  @override
  String get id => 'test/observation';
  @override
  List<ToolSchema> get tools =>
      const [ToolSchema(name: 'example', description: '', inputSchema: {})];
}

void main() {
  test(
      'history snapshots freeze nested inputs and leave the canonical log intact',
      () {
    final input = <String, dynamic>{
      'nested': {
        'values': [1, 2]
      }
    };
    final entry = MessageAppendedEntry(
        turnId: 'old',
        message: Message(role: Role.assistant, content: [
          ToolUseBlock(id: 'call', name: 'example', input: input)
        ]));
    final loop = AgentLoop(
        provider: ScriptedProvider([]), plugins: [], seedLog: [entry]);
    final source = SessionObservationSource()..mountOn(loop);
    addTearDown(source.close);
    final events = <SessionObservationEvent>[];
    final release = source.observation.listen(events.add);
    final copy = (events.single as ObservedEntry).entry as MessageAppendedEntry;
    final copiedInput = (copy.message.content.single as ToolUseBlock).input;
    expect(() => (copiedInput['nested']['values'] as List).add(3),
        throwsUnsupportedError);
    expect(() => copy.message.content.clear(), throwsUnsupportedError);
    expect(jsonEncode(copy.toJson()), jsonEncode(entry.toJson()));
    input['nested']['values'].add(3);
    expect(copiedInput['nested']['values'], [1, 2]);
    source.watch(const SawThinkingEnd(complete: false));
    final ending =
        (source.observation.snapshot['preview'] as List).single as Map;
    expect(ending['complete'], isFalse);
    expect(() => ending['complete'] = true, throwsUnsupportedError);
    release();
    release();
  });

  test(
      'late observers receive current tool state and detaching does not cancel execution',
      () async {
    final loop = AgentLoop(
        provider: ScriptedProvider([
          scriptedReply('', calls: [
            ToolUseBlock(id: 'call', name: 'example', input: {
              'nested': [1]
            })
          ]),
          scriptedReply('finished')
        ]),
        plugins: [_Tool()]);
    final source = SessionObservationSource()..mountOn(loop);
    addTearDown(source.close);
    final started = Completer<void>(), finish = Completer<void>();
    loop.registerContextExecutor('example', (_, execution) async {
      execution.report('partial');
      execution.progress('working');
      started.complete();
      await finish.future;
      execution.report(' remainder');
      return const ToolResult('complete');
    });
    final first = <SessionObservationEvent>[],
        second = <SessionObservationEvent>[];
    final releaseFirst = source.observation.listen(first.add);
    final turn = loop.runTurn(const Input('run', id: 'current'));
    await started.future;
    source.observation.listen(second.add);
    expect(source.observation.running, true);
    expect(
        second.whereType<ObservedActivity>().map((e) => e.activity.runtimeType),
        [ToolStarted, ToolOutput, ToolProgress]);
    final start = second.whereType<ObservedActivity>().first;
    expect(second.whereType<ObservedActivity>().map((e) => e.activity.call),
        everyElement(same(start.activity.call)),
        reason: 'stream chunks share one immutable call snapshot');
    expect(() => (start.activity.call.input['nested'] as List).clear(),
        throwsUnsupportedError);
    expect(first.whereType<ObservedActivity>().first.at, start.at);
    releaseFirst();
    final before = first.length;
    finish.complete();
    expect((await turn).stopReason, StopReason.complete);
    expect(first.length, before);
    expect(second.whereType<ObservedActivity>().last.activity,
        isA<ToolFinished>());
    expect(source.observation.running, false);
    final replay = <SessionObservationEvent>[];
    source.observation.listen(replay.add);
    expect(replay.whereType<ObservedActivity>(), isEmpty,
        reason: 'completed calls use canonical history');
  });

  test('subscriber failures do not interrupt siblings or persistence ordering',
      () async {
    final loop = AgentLoop(
        provider: ScriptedProvider([scriptedReply('answer')]), plugins: []);
    final persisted = <int>{};
    loop.subscribeBatches(
        (entries, _) => persisted.addAll(entries.map((e) => e.seq)));
    final source = SessionObservationSource()..mountOn(loop);
    addTearDown(source.close);
    var failures = 0;
    source.observation.listen((_) {
      failures++;
      throw StateError('renderer failed');
    });
    final received = <int>[];
    source.observation.listen((event) {
      expect(loop.publishing, isFalse);
      if (event is ObservedEntry) {
        expect(persisted, contains(event.entry.seq));
        received.add(event.entry.seq);
      }
    });
    expect((await loop.runTurn(const Input('go', id: 'turn'))).stopReason,
        StopReason.complete);
    expect(failures, 1);
    expect(received, loop.log.map((e) => e.seq));
  });

  test(
      'transient delivery and replay are bounded and announce resynchronization',
      () async {
    final source = SessionObservationSource();
    addTearDown(source.close);
    final live = <SessionObservationEvent>[];
    final release = source.observation.listen(live.add);
    for (var i = 0; i < 5000; i++) source.watch(const SawText('x'));
    expect(live, isEmpty,
        reason: 'rendering never runs in the publishing callback');
    await Future<void>.delayed(Duration.zero);
    expect(live.first, isA<ObservedReset>());
    expect(live, hasLength(3));
    expect(((live[1] as ObservedModel).event as SawText).text, hasLength(4096));
    release();
    final late = <SessionObservationEvent>[];
    source.observation.listen(late.add);
    expect(late, hasLength(2));
    expect((late.last as ObservedModel).event, isA<SawNotice>());
    source.close();
    expect(() => source.observation.listen((_) {}), throwsStateError);
  });
}
