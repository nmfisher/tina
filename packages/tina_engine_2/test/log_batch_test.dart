import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

final class _Owner extends AgentPlugin {
  @override
  String get id => 'test/owner';
}

void main() {
  late ScriptedProvider provider;
  late AgentLoop loop;
  setUp(() {
    provider = ScriptedProvider([scriptedReply('done')]);
    loop = AgentLoop(provider: provider, plugins: [_Owner()]);
  });
  void write() => loop.stateWriter('test/owner')(PluginStateEntry.snapshot(
      pluginId: 'test/owner', stateKey: 'data', schemaVersion: 1, value: {}));

  test('safe boundaries are synchronous, immutable and visible in full',
      () async {
    final batches = <List<String>>[];
    loop.subscribeBatches((entries, event) {
      expect(event, LogEvent.appended);
      expect(
          loop.log.sublist(entries.first.seq, entries.last.seq + 1), entries);
      expect(() => entries.clear(), throwsUnsupportedError);
      batches.add(entries.map((e) => e.kind).toList());
    });
    await loop.runTurn(const Input('hello', id: 'turn'));
    expect(batches, [
      ['turn_started', 'input_recorded'],
      ['message_appended'],
      ['message_appended', 'turn_ended'],
    ]);
    final replay = <SessionEntry>[];
    final handle = loop.subscribeBatches((entries, event) {
      expect(event, LogEvent.replay);
      replay.addAll(entries);
    });
    expect(replay, loop.log);
    loop.unsubscribe(handle);
    write();
    expect(replay, hasLength(5));
  });

  test(
      'nested appends keep every listener in order and persist before returning',
      () async {
    final observed = <int>[];
    final second = <int>[];
    final saved = <int>[];
    // An observer registered before the batch subscriber still sees saved data.
    loop.subscribe((entry, event) {
      observed.add(entry.seq);
      expect(saved, contains(entry.seq));
      if (entry is TurnStartedEntry) {
        write();
        expect(saved, [0, 1, 2]);
      }
    });
    loop.subscribe((entry, _) => second.add(entry.seq));
    loop.subscribeBatches(
        (entries, _) => saved.addAll(entries.map((e) => e.seq)));
    await loop.runTurn(const Input('hello', id: 'turn'));
    final expected = List.generate(loop.log.length, (i) => i);
    expect(observed, expected);
    expect(second, expected);
    expect(saved, expected);
  });

  test('subscribe during delivery replays a snapshot without duplicate appends',
      () async {
    final seen = <int>[];
    loop.subscribe((entry, _) {
      if (entry is TurnStartedEntry) {
        loop.subscribe((entry, _) {
          seen.add(entry.seq);
          if (entry is TurnStartedEntry) write();
        });
      }
    });
    await loop.runTurn(const Input('hello', id: 'turn'));
    expect(seen, List.generate(loop.log.length, (i) => i));
  });

  test('a swallowed nested append error still stops the enclosing turn',
      () async {
    final failure = StateError('save failed');
    var observedInput = false;
    loop.subscribeBatches((entries, _) {
      if (entries.any((e) => e is PluginStateEntry)) throw failure;
    });
    loop.subscribe((entry, _) {
      if (entry is InputRecordedEntry) observedInput = true;
      if (entry is TurnStartedEntry) {
        try {
          write();
        } catch (_) {/* simulate an observer swallowing it */}
      }
    });
    await expectLater(
        loop.runTurn(const Input('hello', id: 'turn')), throwsA(same(failure)));
    expect(provider.callCount, 0);
    expect(observedInput, isFalse);
    expect(loop.running, isFalse);
  });

  test('failed replay removes the subscription', () async {
    write();
    var calls = 0;
    expect(
        () => loop.subscribeBatches((_, __) {
              calls++;
              throw StateError('replay failed');
            }),
        throwsStateError);
    write();
    expect(calls, 1);
  });

  test('a batch subscriber can append while other subscribers are pending',
      () async {
    final first = <int>[];
    final second = <int>[];
    loop.subscribeBatches((entries, _) {
      first.addAll(entries.map((e) => e.seq));
      if (entries.first is TurnStartedEntry) write();
    });
    loop.subscribeBatches(
        (entries, _) => second.addAll(entries.map((e) => e.seq)));
    await loop.runTurn(const Input('hello', id: 'turn'));
    expect(first, List.generate(loop.log.length, (i) => i));
    expect(second, first);
  });
}
