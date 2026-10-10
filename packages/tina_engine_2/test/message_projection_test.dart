// B3: the MessageProjection seam. With no projection registered — today's
// default — AgentLoop.compact appends a CompactedEntry exactly as before;
// a registered projection that accepts serves the splice instead, one that
// declines falls through, and one that throws leaves the log untouched.
// The range is validated against the core derive before any projection runs.
library;

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

final class _Plain extends AgentPlugin {
  const _Plain();
  @override
  String get id => 'test/plain';
}

final class _SpyProjection extends AgentPlugin implements MessageProjection {
  _SpyProjection({this.verdict = 'accept', this.name = 'projection'});
  final String verdict;
  final String name;
  List<MessageSplice> splices = [];

  @override
  String get id => 'test/$name';

  @override
  bool applyCompaction(MessageSplice splice) {
    splices.add(splice);
    switch (verdict) {
      case 'accept':
        return true;
      case 'decline':
        return false;
      case 'throw':
        throw StateError('projection cannot serve this splice');
    }
    throw StateError('unreachable');
  }
}

List<String> kinds(List<SessionEntry> log) => [for (final e in log) e.kind];

void main() {
  Future<AgentLoop> turnedLoop({List<AgentPlugin> plugins = const []}) async {
    final provider = ScriptedProvider([scriptedReply('answer')]);
    final loop = AgentLoop(provider: provider, plugins: plugins);
    await loop.runTurn(const Input('question', id: 'a'));
    return loop;
  }

  test('no projection: CompactedEntry exactly as before', () async {
    final loop = await turnedLoop();
    loop.compact(0, 1, 'summary');
    expect(kinds(loop.log).last, 'compacted');
    final entry = loop.log.last as CompactedEntry;
    expect(entry.replacedFrom, 0);
    expect(entry.replacedTo, 1);
    expect(entry.summary, 'summary');
    expect(
        [for (final m in loop.derive().messages) m.content.single],
        hasLength(1));
    expect(loop.derive().messages.single.isSynthetic, isTrue);
    expect((loop.derive().messages.single.content.single as TextBlock).text,
        'summary');
  });

  test('an accepting projection serves the splice: no entry appended',
      () async {
    final spy = _SpyProjection();
    final loop = await turnedLoop(plugins: [spy]);
    loop.compact(0, 1, 'summary');
    expect(spy.splices, [(from: 0, to: 1, summary: 'summary')]);
    expect(kinds(loop.log).last, isNot('compacted'),
        reason: 'the projection owns it; the log stays untouched');
    expect(kinds(loop.log), everyElement(isNot('compacted')));
  });

  test('a declining projection falls through to the entry', () async {
    final spy = _SpyProjection(verdict: 'decline');
    final loop = await turnedLoop(plugins: [spy]);
    loop.compact(0, 1, 'summary');
    expect(spy.splices, hasLength(1));
    expect(kinds(loop.log).last, 'compacted');
  });

  test('a throwing projection rejects the compaction with nothing appended',
      () async {
    final spy = _SpyProjection(verdict: 'throw');
    final loop = await turnedLoop(plugins: [spy]);
    final before = loop.log.length;
    expect(() => loop.compact(0, 1, 'summary'), throwsStateError);
    expect(loop.log.length, before,
        reason: 'one compaction, never two divergent histories');
  });

  test('the range is validated before projections are consulted', () async {
    final spy = _SpyProjection();
    final loop = await turnedLoop(plugins: [spy]);
    expect(() => loop.compact(5, 9, 'summary'), throwsRangeError);
    expect(spy.splices, isEmpty);
  });

  test('the first registered projection is consulted first', () async {
    final first = _SpyProjection(name: 'first');
    final second = _SpyProjection(name: 'second');
    final loop = await turnedLoop(plugins: [first, second]);
    loop.compact(0, 1, 'summary');
    expect(first.splices, hasLength(1));
    expect(second.splices, isEmpty,
        reason: 'the loop stops at the first accepting projection');
  });

  test('a declining first does not stop the second', () async {
    final declining = _SpyProjection(verdict: 'decline', name: 'declining');
    final accepting = _SpyProjection(name: 'accepting');
    final loop = await turnedLoop(plugins: [declining, accepting]);
    loop.compact(0, 1, 'summary');
    expect(declining.splices, hasLength(1));
    expect(accepting.splices, hasLength(1));
    expect(kinds(loop.log), everyElement(isNot('compacted')));
  });
}
