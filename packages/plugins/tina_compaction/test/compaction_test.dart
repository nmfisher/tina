// Size-triggered compaction: the plugin checks the derived request size
// at turn end, summarizes the older half over the session's own
// provider, and writes the Compacted entry the derive already knows how
// to splice. Tests pin the trigger arithmetic, the turn-boundary split
// (recent turns and tool pairs kept whole), the summary request shape,
// failure handling, and the store round trip — a compacted session
// resumes as the summary plus the kept tail.
//
// Run: dart test
library;

import 'package:tina_persistence/tina_persistence.dart';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_compaction/tina_compaction.dart';

/// A short turn: one user message, one assistant reply. Four chars per
/// estimated token, so a reply of N chars costs about N/4 tokens.
List<StreamEvent> turn(String reply) => scriptedReply(reply);

/// Pump the event loop until the compaction plugin's one-shot summary
/// future has run: the summary rides the provider's async stream, and a
/// fixed double-microtask pump is not always enough.
Future<void> settle() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late Directory ws;

  setUp(() async {
    ws = await Directory.systemTemp.createTemp('tina_compact_ws_');
  });
  tearDown(() {
    ws.deleteSync(recursive: true);
  });

  test('under the threshold nothing fires and no summary is requested',
      () async {
    final provider = ScriptedProvider([turn('one'), turn('two')]);
    final plugin = CompactionPlugin(
      config: const CompactionConfig(thresholdTokens: 100000),
    );
    final host = Host.start(HostConfig(
      providerFactory: (_) => provider,
      workingDirectory: ws.path,
      plugins: [plugin],
    ));
    await host.session.loop.runTurn(const Input('hi', id: 't1'));
    await host.session.loop.runTurn(const Input('again', id: 't2'));
    expect(provider.callCount, 2, reason: 'two turns, no summary request');
    expect(
      provider.requests.any(
        (r) => r.systemPrompt == compactionSummarySystemPrompt(),
      ),
      isFalse,
    );
    expect(
      host.session.loop.log.whereType<CompactedEntry>(),
      isEmpty,
    );
    host.close();
  });

  test(
      'over the threshold: summary requested, Compacted entry written, '
      'derive shows summary + kept tail', () async {
    // Turn replies of ~100 tokens each: the second turn-end crosses the
    // 100-token threshold with two turns in the log. keepRecentTurns: 1
    // keeps the newest turn verbatim, summarizes turn one.
    final big = 'x' * 400; // ~100 tokens
    final provider = ScriptedProvider([
      turn(big),
      turn(big),
      // The summary request's reply:
      scriptedReply('the user said hi and got a big reply'),
    ]);
    final plugin = CompactionPlugin(
      config: const CompactionConfig(thresholdTokens: 100, keepRecentTurns: 1),
    );
    final host = Host.start(HostConfig(
      providerFactory: (_) => provider,
      workingDirectory: ws.path,
      plugins: [plugin],
    ));
    await host.session.loop.runTurn(const Input('hi there', id: 't1'));
    await host.session.loop.runTurn(const Input('more', id: 't2'));
    await settle();

    final compacted =
        host.session.loop.log.whereType<CompactedEntry>().toList();
    expect(compacted, hasLength(1));
    expect(compacted.single.summary,
        contains('the user said hi and got a big reply'));

    // The summary request carried the fixed prompt and turn one's two
    // messages plus the instruction, no tools.
    final summaryRequests = provider.requests
        .where((r) => r.systemPrompt == compactionSummarySystemPrompt())
        .toList();
    expect(summaryRequests, hasLength(1));
    expect(summaryRequests.single.tools, isEmpty);
    expect(summaryRequests.single.messages.length, 3);
    expect(
        summaryRequests.single.messages.last.content.single, isA<TextBlock>());

    // Derive: turn one's two messages are replaced by the synthetic
    // summary; turn two stays verbatim.
    final view = host.session.loop.derive();
    expect(view.messages.length, 3);
    expect(view.messages.first.isSynthetic, isTrue);
    expect(
      (view.messages.first.content.single as TextBlock).text,
      contains('[earlier conversation summarized]'),
    );
    host.close();
  });

  test('the split keeps recent turns and never severs a tool pair', () async {
    // A turn with a tool call: ToolCallStart + completion with a
    // tool_use block, then the tool result, then the closing reply.
    final toolCall = [
      const ToolCallStart(id: 'c1', name: 'write'),
      const MessageComplete(
        content: [
          TextBlock('writing'),
          ToolUseBlock(id: 'c1', name: 'write', input: {'path': 'a.txt'}),
        ],
        stopReason: 'tool_use',
      ),
    ];
    final big = 'x' * 400;
    final provider = ScriptedProvider([
      toolCall,
      // The loop's second step after the tool result closes the turn.
      scriptedReply('done writing'),
      turn(big),
      turn(big),
      scriptedReply('summary of the old half'),
    ]);
    final plugin = CompactionPlugin(
      config: const CompactionConfig(thresholdTokens: 80, keepRecentTurns: 2),
    );
    final host = Host.start(HostConfig(
      providerFactory: (_) => provider,
      workingDirectory: ws.path,
      plugins: [plugin],
    ));
    await host.session.loop.runTurn(const Input('use the tool', id: 't1'));
    await host.session.loop.runTurn(const Input('two', id: 't2'));
    await host.session.loop.runTurn(const Input('three', id: 't3'));
    await settle();

    final compacted =
        host.session.loop.log.whereType<CompactedEntry>().toList();
    expect(compacted, hasLength(1));
    // keepRecentTurns: 2 — turns two and three stay verbatim from turn
    // two's user message, so no tool pair can ever be severed; turn one
    // (with its tool call) is what the summary replaced.
    final view = host.session.loop.derive();
    final summaryAt = view.messages.indexWhere((m) => m.isSynthetic);
    expect(summaryAt, 0);
    expect(view.messages[1].role, Role.user,
        reason: 'the kept tail starts on turn two\'s user message');
    expect(view.messages.length, 5,
        reason: 'summary + turn two (2 msgs) + turn three (2 msgs); '
            'turn one ran to four with the closing reply, all replaced');
    host.close();
  });

  test(
      'a summary request that errors or returns nothing compacts nothing '
      'and the next turn re-checks', () async {
    final big = 'x' * 400;
    final provider = ScriptedProvider([
      turn(big),
      turn(big),
      [const StreamError('boom')],
      turn(big),
      scriptedReply('late summary'),
    ]);
    final plugin = CompactionPlugin(
      config: const CompactionConfig(thresholdTokens: 100, keepRecentTurns: 1),
    );
    final host = Host.start(HostConfig(
      providerFactory: (_) => provider,
      workingDirectory: ws.path,
      plugins: [plugin],
    ));
    await host.session.loop.runTurn(const Input('one', id: 't1'));
    await host.session.loop.runTurn(const Input('two', id: 't2'));
    await settle();
    expect(
      host.session.loop.log.whereType<CompactedEntry>(),
      isEmpty,
      reason: 'the failed summary skips; the trigger is re-armed',
    );
    await host.session.loop.runTurn(const Input('three', id: 't3'));
    await settle();
    expect(host.session.loop.log.whereType<CompactedEntry>(), hasLength(1),
        reason: 'the next crossing summarizes successfully');
    host.close();
  });

  test(
      'the old summary merges into the next compaction — the synthetic '
      'message is never a turn boundary', () async {
    // keepRecentTurns: 1, three big turns. Turn one compacts; then the
    // view is summary + turn two + turn three, still over the
    // threshold: the next compaction folds the old summary and turn two
    // into a new summary — the synthetic rides the prefix like any
    // message — and the kept tail anchors on turn three's real user
    // message.
    final big = 'x' * 400;
    final provider = ScriptedProvider([
      turn(big),
      turn(big),
      scriptedReply('first summary'),
      turn(big),
      scriptedReply('second summary'),
    ]);
    final plugin = CompactionPlugin(
      config: const CompactionConfig(thresholdTokens: 100, keepRecentTurns: 1),
    );
    final host = Host.start(HostConfig(
      providerFactory: (_) => provider,
      workingDirectory: ws.path,
      plugins: [plugin],
    ));
    await host.session.loop.runTurn(const Input('one', id: 't1'));
    await host.session.loop.runTurn(const Input('two', id: 't2'));
    await settle();
    final first = host.session.loop.derive().messages;
    expect(first.first.isSynthetic, isTrue);
    expect((first.first.content.single as TextBlock).text,
        contains('first summary'));
    await host.session.loop.runTurn(const Input('three', id: 't3'));
    await settle();
    final compacted =
        host.session.loop.log.whereType<CompactedEntry>().toList();
    expect(compacted, hasLength(2), reason: 'the merge compaction fired');
    final view = host.session.loop.derive().messages;
    expect(view.first.isSynthetic, isTrue);
    expect((view.first.content.single as TextBlock).text,
        contains('second summary'),
        reason: 'the old summary was folded in');
    expect(view[1].role, Role.user);
    expect(view[1].isSynthetic, isFalse,
        reason: 'the kept tail anchors on a real turn, not the summary');
    host.close();
  });

  test(
      'a compacted session survives the store round trip: the resume '
      'derives the summary and the kept tail', () async {
    final big = 'x' * 400;
    final storePath = '${ws.path}/session.db';
    final provider = ScriptedProvider([
      turn(big),
      turn(big),
      scriptedReply('the whole story so far'),
      // The resumed session's first turn:
      turn('after resume'),
    ]);
    final plugin = CompactionPlugin(
      config: const CompactionConfig(thresholdTokens: 100, keepRecentTurns: 1),
    );
    final started = Host.start(HostConfig(
      providerFactory: (_) => provider,
      workingDirectory: ws.path,
      sessionTitle: 'compacted',
      plugins: [
        plugin,
        PersistencePlugin(openStore: () => SessionStore.open(storePath)),
      ],
    ));
    await started.session.loop.runTurn(const Input('one', id: 't1'));
    await started.session.loop.runTurn(const Input('two', id: 't2'));
    await settle();
    expect(started.session.loop.log.whereType<CompactedEntry>(), hasLength(1));
    final sessionId = started.session.id;
    started.close();

    // A fresh host over the same store: the log replays, the derive
    // splices the summary in, and the next request carries it.
    // The resumed session is still over the threshold, so its first
    // turn ends with another compaction — the old summary and the kept
    // turn merge into one new summary.
    final provider2 = ScriptedProvider([
      turn('after resume'),
      scriptedReply('the merged story'),
    ]);
    final resumed = Host.resume(
      HostConfig(
        providerFactory: (_) => provider2,
        workingDirectory: ws.path,
        plugins: [
          plugin,
          PersistencePlugin(openStore: () => SessionStore.open(storePath)),
        ],
      ),
      sessionId,
    );
    final view = resumed.session.loop.derive();
    expect(view.messages.first.isSynthetic, isTrue);
    expect((view.messages.first.content.single as TextBlock).text,
        contains('the whole story so far'));
    expect(view.messages.length, 3);

    await resumed.session.loop.runTurn(const Input('back', id: 't4'));
    // The resumed session's first real request carries the summary.
    final first = provider2.requests.first;
    expect(first.messages.first.isSynthetic, isTrue);
    expect((first.messages.first.content.single as TextBlock).text,
        contains('the whole story so far'));
    await settle();
    // Still over the threshold, the resumed session compacts once more:
    // the old summary rides in the merged prefix like any other message,
    // and a second Compacted entry lands in the same store slice.
    expect(
      resumed.session.loop.log.whereType<CompactedEntry>(),
      hasLength(2),
      reason: 'the seeded entry plus one more on the resumed session',
    );
    final merged = resumed.session.loop.derive().messages;
    expect(merged.length, 3);
    expect(merged.first.isSynthetic, isTrue);
    expect((merged.first.content.single as TextBlock).text,
        contains('the merged story'));
    expect(
        resumed.config.plugins
            .whereType<PersistencePlugin>()
            .single
            .store
            .checkGaps(sessionId),
        isEmpty,
        reason: 'both hosts appended to one continuous slice');
    resumed.close();
  });
}
