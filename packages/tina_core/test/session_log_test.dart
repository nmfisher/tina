// Session-log entry types + derive function. Every entry case round-trips
// through the same JSON bytes a store row or a JSON Lines line holds, and
// derive is a pure function: same log + same settings, same request.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:tina_core/tina_core.dart';

SessionEntry roundTrip(SessionEntry e) => SessionEntry.fromJson(
    jsonDecode(jsonEncode(e.toJson())) as Map<String, dynamic>);

Message user(String text) =>
    Message(role: Role.user, content: [TextBlock(text)]);

Message assistant(String text) =>
    Message(role: Role.assistant, content: [TextBlock(text)]);

void main() {
  group('entry JSON round-trip', () {
    test('every case survives encode → decode → encode byte-identically', () {
      final entries = <SessionEntry>[
        const UsageRecordedEntry(
            turnId: 't1',
            usage: EntryUsage(inputTokens: 12),
            estimatedTokens: 9,
            child: true,
            at: 'a'),
        const TurnStartedEntry(turnId: 't1', at: '2026-01-01T00:00:00Z'),
        const InputRecordedEntry(turnId: 't1', text: 'as typed', at: 'a'),
        const InputRewrittenEntry(
            turnId: 't1', pluginId: 'spellfix', text: 'as fixed', at: 'a'),
        const MessageAppendedEntry(
            turnId: 't1',
            message: Message(
              role: Role.user,
              content: [
                TextBlock('hi'),
                ToolUseBlock(id: 'u1', name: 'sh', input: {'c': 'ls'})
              ],
              reasoning: [ReasoningBlock('hm', signature: 'sig')],
              isSynthetic: true,
            ),
            at: 'a'),
        const MessageAppendedEntry(
            turnId: 't1',
            message: Message(role: Role.assistant, content: [
              ToolResultBlock(toolUseId: 'u1', content: 'out', isError: true)
            ]),
            at: 'a'),
        const TurnEndedEntry(
            turnId: 't1',
            reason: TurnStopReason.complete,
            usage: const EntryUsage(
                inputTokens: 11,
                outputTokens: 7,
                cacheCreationInputTokens: 3,
                cacheReadInputTokens: 5),
            at: 'a'),
        PluginStateEntry.snapshot(
            pluginId: 'test/state',
            stateKey: 'data',
            schemaVersion: 8,
            value: {'x': 1}),
        const CompactedEntry(
            replacedFrom: 0, replacedTo: 3, summary: 'earlier stuff', at: 'a'),
      ];
      for (final e in entries) {
        final again = roundTrip(e);
        expect(again.runtimeType, e.runtimeType, reason: e.kind);
        expect(jsonEncode(again.toJson()), jsonEncode(e.toJson()),
            reason: e.kind);
      }
    });

    test('unknown type throws instead of being skimmed', () {
      expect(
        () => SessionEntry.fromJson({'type': 'session_nuked'}),
        throwsFormatException,
      );
    });

    test('EntryUsage converts TokenUsage losslessly and sums', () {
      const u = TokenUsage(
          inputTokens: 10,
          outputTokens: 4,
          cacheCreationInputTokens: 2,
          cacheReadInputTokens: 6);
      final e = EntryUsage.fromTokens(u);
      expect(e.inputTokens, 10);
      expect(e.outputTokens, 4);
      expect(e.cacheCreationInputTokens, 2);
      expect(e.cacheReadInputTokens, 6);
      expect(
          e + e,
          const EntryUsage(
              inputTokens: 20,
              outputTokens: 8,
              cacheCreationInputTokens: 4,
              cacheReadInputTokens: 12));
      expect(EntryUsage.fromJson(e.toJson()), e);
    });
  });

  group('deriveSession', () {
    test('one completed turn derives its input message and reply', () {
      final log = <SessionEntry>[
        const TurnStartedEntry(turnId: 't1'),
        const InputRecordedEntry(turnId: 't1', text: 'hello'),
        MessageAppendedEntry(turnId: 't1', message: user('hello')),
        MessageAppendedEntry(turnId: 't1', message: assistant('hi')),
        const TurnEndedEntry(turnId: 't1', reason: TurnStopReason.complete),
      ];
      final d = deriveSession(log, const SessionSettings(systemPrompt: 'p'));
      expect(d.messages.length, 2);
      expect(jsonEncode(d.messages.map((m) => m.toJson()).toList()),
          jsonEncode([user('hello').toJson(), assistant('hi').toJson()]));
      expect(d.pendingTurnId, isNull);
      expect(d.entriesConsumed, log.length);
      expect(d.systemPrompt, 'p');
    });

    test('rewrite: the provider sees the rewritten text; the log keeps the raw',
        () {
      final log = <SessionEntry>[
        const TurnStartedEntry(turnId: 't1'),
        const InputRecordedEntry(turnId: 't1', text: 'helo'),
        const InputRewrittenEntry(
            turnId: 't1', pluginId: 'spellfix', text: 'hello'),
        MessageAppendedEntry(turnId: 't1', message: user('hello')),
        const TurnEndedEntry(turnId: 't1', reason: TurnStopReason.complete),
      ];
      final d = deriveSession(log, const SessionSettings());
      expect((d.messages.single.content.single as TextBlock).text, 'hello');
      // The raw words as typed stay recoverable from the log itself:
      final raw = log.whereType<InputRecordedEntry>().single;
      expect(raw.text, 'helo');
      // ...and the rewrite names its plugin:
      expect(log.whereType<InputRewrittenEntry>().single.pluginId, 'spellfix');
    });

    test('pending (never-ended) turn contributes nothing to the request', () {
      final log = <SessionEntry>[
        const TurnStartedEntry(turnId: 't1'),
        const InputRecordedEntry(turnId: 't1', text: 'half-typed'),
        MessageAppendedEntry(turnId: 't1', message: user('half-typed')),
        const TurnStartedEntry(turnId: 't2'),
        const InputRecordedEntry(turnId: 't2', text: 'next'),
        MessageAppendedEntry(turnId: 't2', message: user('next')),
        MessageAppendedEntry(turnId: 't2', message: assistant('ok')),
        const TurnEndedEntry(turnId: 't2', reason: TurnStopReason.complete),
      ];
      final d = deriveSession(log, const SessionSettings());
      // t1's half-turn is skipped; only t2's completed exchange derives.
      expect(d.messages.length, 2);
      expect((d.messages.first.content.single as TextBlock).text, 'next');
      expect(d.pendingTurnId, 't1');
      // The loop that *is* the writer derives mid-turn with the open
      // turn included: all three messages, same pendingTurnId.
      final mid =
          deriveSession(log, const SessionSettings(), includePendingTurn: true);
      expect(mid.messages.length, 3);
      expect(
        (mid.messages.first.content.single as TextBlock).text,
        'half-typed',
      );
      expect(mid.pendingTurnId, 't1');
    });

    test('opaque state snapshots fold by owner and key, including tombstones',
        () {
      final d = deriveSession([
        PluginStateEntry.snapshot(
            pluginId: 'test/a',
            stateKey: 'x',
            schemaVersion: 99,
            value: {
              'unknown': [1, 2]
            }),
        PluginStateEntry.snapshot(
            pluginId: 'test/b', stateKey: 'x', schemaVersion: 1, value: {}),
        PluginStateEntry.snapshot(
            pluginId: 'test/a', stateKey: 'x', schemaVersion: 99, value: null),
      ], const SessionSettings());
      expect(d.pluginStates['test/a']!['x']!.value, isNull);
      expect(d.pluginStates['test/b']!['x']!.value, isEmpty);
    });

    test('compaction replaces the range with one synthetic summary', () {
      final log = <SessionEntry>[
        const TurnStartedEntry(turnId: 't1'),
        MessageAppendedEntry(turnId: 't1', message: user('q1')),
        MessageAppendedEntry(turnId: 't1', message: assistant('a1')),
        const TurnEndedEntry(turnId: 't1', reason: TurnStopReason.complete),
        const TurnStartedEntry(turnId: 't2'),
        MessageAppendedEntry(turnId: 't2', message: user('q2')),
        MessageAppendedEntry(turnId: 't2', message: assistant('a2')),
        const TurnEndedEntry(turnId: 't2', reason: TurnStopReason.complete),
        const CompactedEntry(
            replacedFrom: 0, replacedTo: 1, summary: 'was q1/a1'),
      ];
      final d = deriveSession(log, const SessionSettings());
      expect(d.messages.length, 3);
      final summary = d.messages.first;
      expect(summary.isSynthetic, isTrue);
      expect(summary.role, Role.user);
      expect((summary.content.single as TextBlock).text, 'was q1/a1');
      expect((d.messages[1].content.single as TextBlock).text, 'q2');
    });

    test('compaction twice: second range addresses the shrunken list', () {
      final log = <SessionEntry>[
        const TurnStartedEntry(turnId: 't1'),
        MessageAppendedEntry(turnId: 't1', message: user('q1')),
        MessageAppendedEntry(turnId: 't1', message: assistant('a1')),
        const TurnEndedEntry(turnId: 't1', reason: TurnStopReason.complete),
        const CompactedEntry(replacedFrom: 0, replacedTo: 1, summary: 's1'),
        const CompactedEntry(replacedFrom: 0, replacedTo: 0, summary: 's2'),
      ];
      final d = deriveSession(log, const SessionSettings());
      expect(d.messages.length, 1);
      expect((d.messages.single.content.single as TextBlock).text, 's2');
      expect(d.messages.single.isSynthetic, isTrue);
    });

    test(
        'a summary standing in for a full turn survives the snap; a range '
        'covering only an open turn does not exist by construction', () {
      // Compaction happens between turns, so a range always addresses
      // completed history; but the snap rule still holds for the turn
      // after it: history derives, the open tail does not.
      final log = <SessionEntry>[
        const TurnStartedEntry(turnId: 't1'),
        MessageAppendedEntry(turnId: 't1', message: user('q1')),
        const TurnEndedEntry(turnId: 't1', reason: TurnStopReason.complete),
        const CompactedEntry(replacedFrom: 0, replacedTo: 0, summary: 's'),
        const TurnStartedEntry(turnId: 't2'),
        MessageAppendedEntry(turnId: 't2', message: user('q2')),
      ];
      final d = deriveSession(log, const SessionSettings());
      expect(d.messages.length, 1); // only the summary; t2 is open
      expect(d.pendingTurnId, 't2');
    });

    test('out-of-range compaction invents no deletions', () {
      final log = <SessionEntry>[
        const TurnStartedEntry(turnId: 't1'),
        MessageAppendedEntry(turnId: 't1', message: user('q1')),
        const TurnEndedEntry(turnId: 't1', reason: TurnStopReason.complete),
        const CompactedEntry(replacedFrom: 5, replacedTo: 9, summary: 'nope'),
      ];
      final d = deriveSession(log, const SessionSettings());
      expect((d.messages.single.content.single as TextBlock).text, 'q1');
    });

    test('derive is pure: same log twice, same request', () {
      final log = <SessionEntry>[
        const TurnStartedEntry(turnId: 't1'),
        const InputRecordedEntry(turnId: 't1', text: 'x'),
        MessageAppendedEntry(turnId: 't1', message: user('x')),
        const TurnEndedEntry(turnId: 't1', reason: TurnStopReason.complete),
      ];
      final a = deriveSession(log, const SessionSettings(systemPrompt: 'p'));
      final b = deriveSession(log, const SessionSettings(systemPrompt: 'p'));
      expect(jsonEncode(a.messages.map((m) => m.toJson()).toList()),
          jsonEncode(b.messages.map((m) => m.toJson()).toList()));
    });
  });

  group('derivation directives', () {
    /// Two completed turns, seq-stamped like the loop would write them.
    List<SessionEntry> twoTurns() => [
          const TurnStartedEntry(turnId: 't1', at: '2026-01-01T10:00:00Z'),
          const InputRecordedEntry(
              turnId: 't1', text: 'first', at: '2026-01-01T10:00:00Z'),
          MessageAppendedEntry(
              turnId: 't1', message: user('first'), at: '2026-01-01T10:00:00Z'),
          MessageAppendedEntry(turnId: 't1', message: assistant('a1')),
          const TurnEndedEntry(turnId: 't1', reason: TurnStopReason.complete),
          const TurnStartedEntry(turnId: 't2', at: '2026-01-01T10:01:00Z'),
          const InputRecordedEntry(
              turnId: 't2', text: 'second', at: '2026-01-01T10:01:00Z'),
          MessageAppendedEntry(
              turnId: 't2',
              message: user('second'),
              at: '2026-01-01T10:01:00Z'),
          MessageAppendedEntry(turnId: 't2', message: assistant('a2')),
          const TurnEndedEntry(turnId: 't2', reason: TurnStopReason.complete),
        ].asMap().map((i, e) => MapEntry(i, e.withSeq(i))).values.toList();

    test('both directive kinds expose the family discriminator', () {
      const compact =
          CompactedEntry(replacedFrom: 0, replacedTo: 1, summary: 's');
      const cut = CutEntry(toSeq: 2);
      expect(compact.directiveKind, DerivationDirectiveKind.compact);
      expect(compact, isA<DerivationDirective>());
      expect(cut.directiveKind, DerivationDirectiveKind.cut);
      expect(cut, isA<DerivationDirective>());
    });

    test('CutEntry round-trips through JSON', () {
      final e = roundTrip(CutEntry(toSeq: 7, at: 'x').withSeq(10));
      expect(e, isA<CutEntry>());
      expect((e as CutEntry).toSeq, 7);
      expect(e.at, 'x');
      expect(e.seq, 10);
      expect(e.toJson()['type'], 'cut');
    });

    test('the legacy rewound wire type is read as a cut directive', () {
      // Logs persisted before the family existed carry type 'rewound';
      // they must keep deriving exactly as they did.
      final legacy = SessionEntry.fromJson({
        'type': CutEntry.legacyRewoundKind,
        'to_seq': 5,
        'seq': 10,
      });
      expect(legacy, isA<CutEntry>());
      expect((legacy as CutEntry).toSeq, 5);
      final base = twoTurns();
      final d = deriveSession([...base, legacy], const SessionSettings());
      expect(d.messages.length, 2);
      expect((d.messages[0].content.single as TextBlock).text, 'first');
    });

    test('a cut directive derives exactly the log prefix before the cut', () {
      final base = twoTurns();
      // Cut to before t2 started (seq 5): t2 never happened.
      final log = [...base, CutEntry(toSeq: 5).withSeq(10)];
      final d = deriveSession(log, const SessionSettings());
      expect(d.messages.length, 2);
      expect((d.messages[0].content.single as TextBlock).text, 'first');
      expect((d.messages[1].content.single as TextBlock).text, 'a1');
      // entriesConsumed still counts the raw log — nothing was deleted.
      expect(d.entriesConsumed, log.length);
      expect(d.pendingTurnId, isNull);
    });

    test('entries appended after the directive stay live', () {
      final base = twoTurns();
      final log = [
        ...base,
        CutEntry(toSeq: 5).withSeq(10),
        const TurnStartedEntry(turnId: 't3'),
        const InputRecordedEntry(turnId: 't3', text: 'third'),
        MessageAppendedEntry(turnId: 't3', message: user('third')),
        MessageAppendedEntry(turnId: 't3', message: assistant('a3')),
        const TurnEndedEntry(turnId: 't3', reason: TurnStopReason.complete),
      ].asMap().map((i, e) => MapEntry(i, e.withSeq(i))).values.toList();
      final d = deriveSession(log, const SessionSettings());
      expect(
        d.messages.map((m) => (m.content.single as TextBlock).text).toList(),
        ['first', 'a1', 'third', 'a3'],
      );
    });

    test('a later directive wins; an earlier one in its dead range drops', () {
      final base = twoTurns();
      // First cut kills t2 (to seq 5); work continues; a second cut goes
      // back to seq 2 — t1's start and input. Everything from seq 2 on
      // is dead, including the first directive: it never happened either.
      // The kept prefix is t1's start + input with no end, so the snap
      // rule leaves an empty derive pending t1's replay.
      final log = [
        ...base,
        CutEntry(toSeq: 5).withSeq(10),
        MessageAppendedEntry(turnId: 't9', message: user('post')),
        CutEntry(toSeq: 2).withSeq(12),
      ].asMap().map((i, e) => MapEntry(i, e.withSeq(i))).values.toList();
      final d = deriveSession(log, const SessionSettings());
      expect(d.messages, isEmpty);
      expect(d.pendingTurnId, 't1');
    });

    test('cutting before a compaction re-derives from the raw entries', () {
      final log = [
        const TurnStartedEntry(turnId: 't1'),
        MessageAppendedEntry(turnId: 't1', message: user('q1')),
        MessageAppendedEntry(turnId: 't1', message: assistant('a1')),
        const TurnEndedEntry(turnId: 't1', reason: TurnStopReason.complete),
        const TurnStartedEntry(turnId: 't2'),
        MessageAppendedEntry(turnId: 't2', message: user('q2')),
        MessageAppendedEntry(turnId: 't2', message: assistant('a2')),
        const TurnEndedEntry(turnId: 't2', reason: TurnStopReason.complete),
        const CompactedEntry(
            replacedFrom: 0, replacedTo: 3, summary: 'was q1/a1 and q2'),
        CutEntry(toSeq: 8), // before the compaction entry (seq 8)
      ].asMap().map((i, e) => MapEntry(i, e.withSeq(i))).values.toList();
      final d = deriveSession(log, const SessionSettings());
      // The compaction is dead; the raw turns derive untouched.
      expect(
        d.messages.map((m) => (m.content.single as TextBlock).text).toList(),
        ['q1', 'a1', 'q2', 'a2'],
      );
      expect(d.messages.any((m) => m.isSynthetic), isFalse);
    });

    test('a cut before a compact keeps both live: both directives apply', () {
      // Out of order in the sense that matters: the cut's bound precedes
      // the compact directive, but the compact sits AFTER the cut and
      // outside its range — it stays live and folds into the derive.
      final log = [
        const TurnStartedEntry(turnId: 't1'),
        MessageAppendedEntry(turnId: 't1', message: user('q1')),
        MessageAppendedEntry(turnId: 't1', message: assistant('a1')),
        const TurnEndedEntry(turnId: 't1', reason: TurnStopReason.complete),
        const TurnStartedEntry(turnId: 't2'),
        MessageAppendedEntry(turnId: 't2', message: user('q2')),
        MessageAppendedEntry(turnId: 't2', message: assistant('a2')),
        const TurnEndedEntry(turnId: 't2', reason: TurnStopReason.complete),
        CutEntry(toSeq: 5).withSeq(8), // t2 never happened
        const CompactedEntry(replacedFrom: 0, replacedTo: 0, summary: 'was q1'),
      ].asMap().map((i, e) => MapEntry(i, e.withSeq(i))).values.toList();
      final d = deriveSession(log, const SessionSettings());
      expect(
        d.messages.map((m) => (m.content.single as TextBlock).text).toList(),
        ['was q1', 'a1'],
      );
      // The summary stands in for the replaced range.
      expect(d.messages.first.isSynthetic, isTrue);
    });

    test('activeLog returns the log itself when no directive exists', () {
      final base = twoTurns();
      expect(activeLog(base), same(base));
    });
  });
}
