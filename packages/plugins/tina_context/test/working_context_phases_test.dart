import 'package:test/test.dart';
import 'package:tina_context/tina_context.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

Message text(String value, [Role role = Role.user]) =>
    Message(role: role, content: [TextBlock(value)]);

List<SessionEntry> stamp(List<SessionEntry> entries) => [
      for (var i = 0; i < entries.length; i++) entries[i].withSeq(i),
    ];

PluginStateEntry snapshotEntry(int revision, int throughSeq,
        {String? turn, String value = 'notes'}) =>
    WorkingContextSnapshot(
      revision: revision,
      throughSeq: throughSeq,
      originTurnId: turn,
      messages: [text(value)],
    ).toEntry();

void main() {
  group('TurnLedger.scan', () {
    test('classifies completed, open and pending turns', () {
      final ledger = TurnLedger.scan(stamp([
        const TurnStartedEntry(turnId: 'a'),
        const TurnEndedEntry(turnId: 'a', reason: TurnStopReason.complete),
        const TurnStartedEntry(turnId: 'b'),
        MessageAppendedEntry(turnId: 'b', message: text('pending')),
      ]));
      expect(ledger.completedTurns, {'a'});
      expect(ledger.openTurns, ['b']);
      expect(ledger.pendingTurnId, 'b');
    });

    test('a clear resets open turns and records the boundary', () {
      final ledger = TurnLedger.scan(stamp([
        const TurnStartedEntry(turnId: 'a'),
        const ContextClearedEntry(),
        const TurnStartedEntry(turnId: 'b'),
        const TurnEndedEntry(turnId: 'b', reason: TurnStopReason.complete),
      ]));
      expect(ledger.clearedAt, 1);
      expect(ledger.openTurns, isEmpty);
      expect(ledger.pendingTurnId, isNull);
    });

    test('a sequence gap throws before any later phase runs', () {
      final log = stamp([
        const TurnStartedEntry(turnId: 'a'),
        const TurnEndedEntry(turnId: 'a', reason: TurnStopReason.complete),
      ]);
      log[1] = log[1].withSeq(5);
      expect(() => TurnLedger.scan(log), throwsFormatException);
    });

    test('eligibility: unattributed and completed always, pending only '
        'when active', () {
      final ledger = TurnLedger.scan(stamp([
        const TurnStartedEntry(turnId: 'done'),
        const TurnEndedEntry(turnId: 'done', reason: TurnStopReason.complete),
        const TurnStartedEntry(turnId: 'open'),
      ]));
      expect(ledger.isEligible(null, activeTurn: null), isTrue);
      expect(ledger.isEligible('done', activeTurn: null), isTrue);
      expect(ledger.isEligible('open', activeTurn: null), isFalse,
          reason: 'an abandoned turn is never live without the policy');
      expect(ledger.isEligible('open', activeTurn: 'open'), isTrue);
      expect(ledger.isEligible('other', activeTurn: 'open'), isFalse);
    });
  });

  group('SnapshotFold.resolve', () {
    test('no entries: no live snapshot, revision watermark 0', () {
      final log = stamp([
        const TurnStartedEntry(turnId: 'a'),
        MessageAppendedEntry(turnId: 'a', message: text('q')),
        const TurnEndedEntry(turnId: 'a', reason: TurnStopReason.complete),
      ]);
      final ledger = TurnLedger.scan(log);
      final fold = SnapshotFold.resolve(log, ledger, activeTurn: null);
      expect(fold.live, isNull);
      expect(fold.maxRevision, 0);
    });

    test('latest eligible snapshot wins; superseded ones keep their '
        'revision credit', () {
      // The mid-turn edit: snapshot b taken while turn a is still open —
      // exactly the ownership the fold validates (origin == pending).
      final log = stamp([
        const TurnStartedEntry(turnId: 'a'),
        MessageAppendedEntry(turnId: 'a', message: text('q')),
        snapshotEntry(1, 1, turn: 'a', value: 'first'),
        snapshotEntry(2, 2, turn: 'a', value: 'second'),
        const TurnEndedEntry(turnId: 'a', reason: TurnStopReason.complete),
      ]);
      final ledger = TurnLedger.scan(log);
      final fold = SnapshotFold.resolve(log, ledger, activeTurn: null);
      expect(fold.live!.messages.single.content.single, isA<TextBlock>());
      expect(
          (fold.live!.messages.single.content.single as TextBlock).text,
          'second');
      expect(fold.maxRevision, 2);
    });

    test('a snapshot before the clear is not live but still counts for '
        'the watermark', () {
      final log = stamp([
        const TurnStartedEntry(turnId: 'a'),
        snapshotEntry(3, 0, turn: 'a'),
        const TurnEndedEntry(turnId: 'a', reason: TurnStopReason.complete),
        const ContextClearedEntry(),
      ]);
      final ledger = TurnLedger.scan(log);
      final fold = SnapshotFold.resolve(log, ledger, activeTurn: null);
      expect(fold.live, isNull);
      expect(fold.maxRevision, 3);
    });

    test('an abandoned origin turn is not live with includePendingTurn '
        'off', () {
      final log = stamp([
        const TurnStartedEntry(turnId: 'a'),
        MessageAppendedEntry(turnId: 'a', message: text('q')),
        snapshotEntry(1, 1, turn: 'a'),
      ]);
      final ledger = TurnLedger.scan(log);
      final fold = SnapshotFold.resolve(log, ledger, activeTurn: null);
      expect(fold.live, isNull);
      final live = SnapshotFold.resolve(log, ledger, activeTurn: 'a');
      expect(live.live, isNotNull);
    });

    test('watermarks, throughSeq chaining and turn ownership are '
        'validated even for superseded entries', () {
      // Revision regression: rejected.
      expect(
        () => SnapshotFold.resolve(
          stamp([
            snapshotEntry(2, 0),
            snapshotEntry(1, 1),
          ]),
          TurnLedger.scan(const []),
          activeTurn: null,
        ),
        throwsFormatException,
      );
      // throughSeq must chain entry-by-entry.
      expect(
        () => SnapshotFold.resolve(
          stamp([
            snapshotEntry(1, 0),
            snapshotEntry(2, 0),
          ]),
          TurnLedger.scan(const []),
          activeTurn: null,
        ),
        throwsFormatException,
      );
      // An origin turn that did not own the prefix's pending turn.
      expect(
        () => SnapshotFold.resolve(
          stamp([
            const TurnStartedEntry(turnId: 'a'),
            snapshotEntry(1, 0, turn: 'b'),
          ]),
          TurnLedger.scan(const []),
          activeTurn: 'b',
        ),
        throwsFormatException,
      );
    });
  });

  group('assembleContextMessages', () {
    test('no snapshot: the core derivation answers, compaction applied',
        () {
      final log = stamp([
        const TurnStartedEntry(turnId: 'a'),
        MessageAppendedEntry(turnId: 'a', message: text('one')),
        MessageAppendedEntry(turnId: 'a', message: text('two')),
        const TurnEndedEntry(turnId: 'a', reason: TurnStopReason.complete),
        const CompactedEntry(
            replacedFrom: 0, replacedTo: 1, summary: 'summarized'),
      ]);
      final messages = assembleContextMessages(
        log,
        ledger: TurnLedger.scan(log),
        snapshot: null,
        activeTurn: null,
        includePendingTurn: false,
      );
      expect(messages, hasLength(1));
      expect((messages.single.content.single as TextBlock).text, 'summarized');
    });

    test('snapshot base plus eligible tail appends, exactly once', () {
      final log = stamp([
        const TurnStartedEntry(turnId: 'a'),
        MessageAppendedEntry(turnId: 'a', message: text('in-snapshot')),
        const TurnEndedEntry(turnId: 'a', reason: TurnStopReason.complete),
        snapshotEntry(1, 2, turn: 'a', value: 'base'),
        MessageAppendedEntry(turnId: 'a', message: text('tail-completed')),
        const TurnStartedEntry(turnId: 'b'),
        MessageAppendedEntry(turnId: 'b', message: text('tail-open')),
      ]);
      final ledger = TurnLedger.scan(log);
      final messages = assembleContextMessages(
        log,
        ledger: ledger,
        snapshot: WorkingContextSnapshot.fromEntry(log[3] as PluginStateEntry),
        activeTurn: null,
        includePendingTurn: false,
      );
      expect(
        [for (final m in messages) (m.content.single as TextBlock).text],
        ['base', 'tail-completed'],
        reason: 'the open turn b is excluded without the policy',
      );
      final withPending = assembleContextMessages(
        log,
        ledger: ledger,
        snapshot: WorkingContextSnapshot.fromEntry(log[3] as PluginStateEntry),
        activeTurn: 'b',
        includePendingTurn: true,
      );
      expect(
        [for (final m in withPending) (m.content.single as TextBlock).text],
        ['base', 'tail-completed', 'tail-open'],
      );
    });

    test('compaction after an edit refuses rather than splicing', () {
      final log = stamp([
        const TurnStartedEntry(turnId: 'a'),
        MessageAppendedEntry(turnId: 'a', message: text('q')),
        const TurnEndedEntry(turnId: 'a', reason: TurnStopReason.complete),
        snapshotEntry(1, 2, turn: 'a'),
        const CompactedEntry(
            replacedFrom: 0, replacedTo: 0, summary: 'later compaction'),
      ]);
      expect(
        () => assembleContextMessages(
          log,
          ledger: TurnLedger.scan(log),
          snapshot: WorkingContextSnapshot.fromEntry(log[3] as PluginStateEntry),
          activeTurn: null,
          includePendingTurn: false,
        ),
        throwsStateError,
      );
    });
  });

  group('deriveWorkingContext over the phases', () {
    test('full replay equals core derive, snapshot path equals base+tail',
        () {
      final head = [
        const TurnStartedEntry(turnId: 'a'),
        MessageAppendedEntry(turnId: 'a', message: text('question')),
        MessageAppendedEntry(
            turnId: 'a', message: text('answer', Role.assistant)),
        const TurnEndedEntry(turnId: 'a', reason: TurnStopReason.complete),
      ];
      final full = stamp(head);
      final replayed = deriveWorkingContext(full);
      expect(replayed.throughSeq, full.length - 1);
      expect(replayed.revision, 0);
      expect(
        [
          for (final m in replayed.messages)
            (m.content.single as TextBlock).text
        ],
        ['question', 'answer'],
      );

      // Edit after the completed turn (origin null), then a next-turn
      // append + end attributed to turn b so the tail is eligible.
      final edited = stamp([
        ...head,
        snapshotEntry(1, 3, value: 'base'),
        const TurnStartedEntry(turnId: 'b'),
        MessageAppendedEntry(turnId: 'b', message: text('tail')),
        const TurnEndedEntry(turnId: 'b', reason: TurnStopReason.complete),
      ]);
      final fromSnapshot = deriveWorkingContext(edited);
      expect(fromSnapshot.revision, 1);
      expect(
        [
          for (final m in fromSnapshot.messages)
            (m.content.single as TextBlock).text
        ],
        ['base', 'tail'],
      );
    });
  });
}
