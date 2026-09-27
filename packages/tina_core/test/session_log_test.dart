// Session-log entry types + derive function. Every entry case round-trips
// through the same JSON bytes a store row or a JSON Lines line holds, and
// derive is a pure function: same log + same settings, same request.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:tina_core/tina_core.dart';

SessionEntry roundTrip(SessionEntry e) =>
    SessionEntry.fromJson(jsonDecode(jsonEncode(e.toJson())) as Map<String, dynamic>);

Message user(String text) =>
    Message(role: Role.user, content: [TextBlock(text)]);

Message assistant(String text) =>
    Message(role: Role.assistant, content: [TextBlock(text)]);

void main() {
  group('entry JSON round-trip', () {
    test('every case survives encode → decode → encode byte-identically', () {
      final entries = <SessionEntry>[
        const TurnStartedEntry(turnId: 't1', at: '2026-01-01T00:00:00Z'),
        const InputRecordedEntry(turnId: 't1', text: 'as typed', at: 'a'),
        const InputRewrittenEntry(
            turnId: 't1', pluginId: 'spellfix', text: 'as fixed', at: 'a'),
        const MessageAppendedEntry(
            turnId: 't1',
            message: Message(
              role: Role.user,
              content: [TextBlock('hi'), ToolUseBlock(id: 'u1', name: 'sh', input: {'c': 'ls'})],
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
        const ModeChangedEntry(mode: 'read-only', at: 'a'),
        const CompactedEntry(
            replacedFrom: 0, replacedTo: 3, summary: 'earlier stuff', at: 'a'),
        WorkflowRunEntry.record(
            workflow: 'default',
            status: WorkflowRunEntry.statusSuccess,
            detail: 'the last node said so',
            nodes: ['start', 'intake', 'done'],
            at: 'a'),
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
      expect(e + e,
          const EntryUsage(inputTokens: 20, outputTokens: 8, cacheCreationInputTokens: 4, cacheReadInputTokens: 12));
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
      expect(d.mode, 'normal');
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
      final mid = deriveSession(log, const SessionSettings(),
          includePendingTurn: true);
      expect(mid.messages.length, 3);
      expect(
        (mid.messages.first.content.single as TextBlock).text,
        'half-typed',
      );
      expect(mid.pendingTurnId, 't1');
    });

    test('mode changes override the setting', () {
      final log = <SessionEntry>[
        const ModeChangedEntry(mode: 'read-only'),
        const ModeChangedEntry(mode: 'normal'),
      ];
      final d = deriveSession(
          log, const SessionSettings(systemPrompt: 'p', mode: 'normal'));
      expect(d.mode, 'normal');
      final d2 = deriveSession(
          [const ModeChangedEntry(mode: 'read-only')],
          const SessionSettings(mode: 'normal'));
      expect(d2.mode, 'read-only');
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
        const CompactedEntry(replacedFrom: 0, replacedTo: 1, summary: 'was q1/a1'),
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

    test('a summary standing in for a full turn survives the snap; a range '
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
      expect(a.mode, b.mode);
    });

    test('the latest workflow_run wins in a derive; earlier runs are history',
        () {
      final log = <SessionEntry>[
        WorkflowRunEntry.record(
            workflow: 'default', status: WorkflowRunEntry.statusFailed),
        const TurnStartedEntry(turnId: 't1'),
        const InputRecordedEntry(turnId: 't1', text: 'go'),
        const TurnEndedEntry(turnId: 't1', reason: TurnStopReason.complete),
        WorkflowRunEntry.record(
            workflow: 'default',
            status: WorkflowRunEntry.statusSuccess,
            detail: 'plan approved and built',
            nodes: ['intake', 'plan', 'done']),
      ];
      final d = deriveSession(log, const SessionSettings());
      expect(d.workflowRun, isNotNull);
      expect(d.workflowRun!.workflow, 'default');
      expect(d.workflowRun!.status, WorkflowRunEntry.statusSuccess);
      expect(d.workflowRun!.detail, 'plan approved and built');
      expect(d.workflowRun!.nodes, ['intake', 'plan', 'done']);
      expect(d.workflowRun!.isSuccess, isTrue);
      // No entry, no run.
      final empty = deriveSession(
          const [
            TurnStartedEntry(turnId: 't1'),
            TurnEndedEntry(turnId: 't1', reason: TurnStopReason.complete),
          ],
          const SessionSettings());
      expect(empty.workflowRun, isNull);
    });

    test('workflow_run survives a store round trip and derives the same',
        () {
      final entry = WorkflowRunEntry.record(
          workflow: 'review',
          status: WorkflowRunEntry.statusFailed,
          detail: 'workflow "review" is invalid: no start node',
          nodes: ['start']);
      final decoded =
          SessionEntry.fromJson(jsonDecode(jsonEncode(entry.toJson()))
              as Map<String, dynamic>) as WorkflowRunEntry;
      expect(decoded, entry);
      final d = deriveSession(
          [decoded, const TurnStartedEntry(turnId: 't1')],
          const SessionSettings());
      expect(d.workflowRun!.status, WorkflowRunEntry.statusFailed);
    });

    test('workflow_run rejects a bogus status and a missing workflow name',
        () {
      expect(
        () => WorkflowRunEntry.record(
            workflow: '', status: WorkflowRunEntry.statusSuccess),
        throwsFormatException,
      );
      expect(
        () => WorkflowRunEntry.record(
            workflow: 'default', status: 'aborted'),
        throwsFormatException,
      );
      expect(
        () => SessionEntry.fromJson(
            {'type': 'workflow_run', 'workflow': 'w', 'status': 'weird'}),
        throwsFormatException,
      );
      expect(
        () => SessionEntry.fromJson(
            {'type': 'workflow_run', 'status': 'success'}),
        throwsFormatException,
      );
    });
  });
}
