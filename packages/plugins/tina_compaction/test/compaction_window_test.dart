// Window-derived compaction (commit 34): the automatic trigger follows
// the active model's context window, read LIVE each turn through the
// plugin's seams — a /model switch (here: the closure's return value
// changing) moves the trigger without a restart. The kept-recent tail
// scales with the window; an unknown window falls back to the safe
// fixed default; an absolute override (including 0 = disabled) wins.
// The explicit-config path keeps its historical fixed semantics.
//
// Run: dart test
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_compaction/tina_compaction.dart';

/// A short turn: one user message, one assistant reply. Four chars per
/// estimated token, so a reply of N chars costs about N/4 tokens.
List<StreamEvent> turn(String reply) => scriptedReply(reply);

/// Pump the event loop until the compaction plugin's one-shot summary
/// future has run (same shape as compaction_test.dart's settle).
Future<void> settle() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('the window arithmetic (named fractions, not magic numbers)', () {
    test('a 1M window triggers at 800K and keeps a 100K tail', () {
      expect(windowCompactionThreshold(1000000), 800000);
      expect(windowKeptRecentTokens(1000000), 100000);
      expect(effectiveCompactionThreshold(contextWindow: 1000000), 800000);
      expect(effectiveKeptRecentTokens(contextWindow: 1000000), 100000);
    });

    test('a 65K window triggers at 52K — before the window fills', () {
      expect(windowCompactionThreshold(65000), 52000);
      expect(windowCompactionThreshold(65000), lessThan(65000));
      // The tail floor holds on small windows.
      expect(windowKeptRecentTokens(65000), compactionMinKeptRecentTokens);
    });

    test('an unknown window falls back to the safe fixed defaults', () {
      expect(effectiveCompactionThreshold(contextWindow: null),
          compactionFallbackThresholdTokens);
      expect(effectiveCompactionThreshold(contextWindow: null), 100000);
      expect(effectiveKeptRecentTokens(contextWindow: null),
          compactionMinKeptRecentTokens);
      // A nonpositive window is unresolvable, not a zero trigger.
      expect(effectiveCompactionThreshold(contextWindow: 0), 100000);
    });

    test('an absolute override wins; a written 0 disables', () {
      expect(
          effectiveCompactionThreshold(
              contextWindow: 1000000, overrideTokens: 5000),
          5000);
      expect(
          effectiveCompactionThreshold(
              contextWindow: 1000000, overrideTokens: 0),
          0);
      expect(
          effectiveCompactionThreshold(
              contextWindow: null, overrideTokens: 0),
          0);
    });
  });

  late Directory ws;
  setUp(() async {
    ws = await Directory.systemTemp.createTemp('tina_compact_window_');
  });
  tearDown(() {
    ws.deleteSync(recursive: true);
  });

  Host hostWith(ScriptedProvider provider, CompactionPlugin plugin) {
    final host = Host.start(HostConfig(
      providerFactory: (_) => provider,
      workingDirectory: ws.path,
      plugins: [plugin],
    ));
    addTearDown(host.close);
    return host;
  }

  test('a 1M-window model compacts near 800K, NOT at 100K', () async {
    // Two exchanges of ~100K estimated tokens each: past the old fixed
    // default, far below the window-derived trigger. Then one exchange
    // that crosses 800K.
    final provider = ScriptedProvider([
      turn('a' * 400000), // ~100K tokens
      turn('b' * 400000), // ~200K total
      turn('c' * 2400100), // ~800K total: over the trigger
      scriptedReply('summary of the old half'),
    ]);
    final host = hostWith(
        provider, CompactionPlugin(readContextWindow: () => 1000000));
    await host.send('one');
    await host.send('two');
    expect(provider.callCount, 2,
        reason: '200K is past the old 100K default but under 80% of 1M');
    expect(host.session.loop.log.whereType<CompactedEntry>(), isEmpty);
    await host.send('three');
    expect(provider.callCount, 4, reason: 'the crossing turn plus its summary');
    expect(host.session.loop.log.whereType<CompactedEntry>(), hasLength(1));
  });

  test('a 65K-window model compacts before the window fills', () async {
    // 30K + 30K estimated tokens: over the 52K trigger, still under the
    // 65K window — the old fixed 100K default would never have fired.
    final provider = ScriptedProvider([
      turn('a' * 120000), // ~30K tokens
      turn('b' * 120000), // ~60K total: over 52K, under the 65K window
      scriptedReply('summary'),
    ]);
    final host =
        hostWith(provider, CompactionPlugin(readContextWindow: () => 65000));
    await host.send('one');
    expect(provider.callCount, 1);
    expect(host.session.loop.log.whereType<CompactedEntry>(), isEmpty);
    await host.send('two');
    expect(provider.callCount, 3);
    expect(host.session.loop.log.whereType<CompactedEntry>(), hasLength(1));
  });

  test('a /model switch moves the trigger live, both directions', () async {
    // Start on a 1M window: 200K of history stays uncompacted. Switch
    // to a 65K window: the SAME history is now over the 52K trigger and
    // the next turn end compacts it. Switch back to 1M: the remaining
    // history is under 800K again and nothing fires.
    var window = 1000000;
    final provider = ScriptedProvider([
      turn('a' * 400000), // ~100K
      turn('b' * 400000), // ~200K total
      turn('ok'), // first turn on the small window: compacts at its end
      scriptedReply('summary after the switch'),
      turn('ok'), // back on the big window: nothing fires
    ]);
    final host = hostWith(
        provider, CompactionPlugin(readContextWindow: () => window));
    await host.send('one');
    await host.send('two');
    expect(provider.callCount, 2);
    expect(host.session.loop.log.whereType<CompactedEntry>(), isEmpty);

    window = 65000; // the /model switch
    await host.send('three');
    expect(provider.callCount, 4,
        reason: 'the switch lowers the trigger; the turn end compacts');
    expect(host.session.loop.log.whereType<CompactedEntry>(), hasLength(1));

    window = 1000000; // switch back
    await host.send('four');
    expect(provider.callCount, 5,
        reason: 'the remaining history is far under the big-window trigger');
    expect(host.session.loop.log.whereType<CompactedEntry>(), hasLength(1));
  });

  test('an absolute override replaces the window fraction', () async {
    // Window 1M (trigger would be 800K) but the override says 30K:
    // ~40K of history fires on the second turn.
    final provider = ScriptedProvider([
      turn('a' * 80000), // ~20K
      turn('b' * 80000), // ~40K total: over the 30K override
      scriptedReply('summary'),
    ]);
    final host = hostWith(
        provider,
        CompactionPlugin(
          readContextWindow: () => 1000000,
          readThresholdOverride: () => 30000,
        ));
    await host.send('one');
    expect(provider.callCount, 1);
    await host.send('two');
    expect(provider.callCount, 3);
    expect(host.session.loop.log.whereType<CompactedEntry>(), hasLength(1));
  });

  test('a written 0 disables automatic compaction; /compact still works',
      () async {
    final provider = ScriptedProvider([
      turn('a' * 400000), // ~100K: over every default trigger
      turn('b' * 400000), // ~200K
      scriptedReply('manual summary'),
    ]);
    final host = hostWith(
        provider,
        CompactionPlugin(
          readContextWindow: () => 65000,
          readThresholdOverride: () => 0,
        ));
    await host.send('one');
    await host.send('two');
    expect(provider.callCount, 2, reason: 'disabled: no summary request');
    expect(host.session.loop.log.whereType<CompactedEntry>(), isEmpty);
    // /compact bypasses the automatic trigger (and minMessagesToCompact).
    await host.commands['compact']!.handler('');
    expect(provider.callCount, 3);
    expect(host.session.loop.log.whereType<CompactedEntry>(), hasLength(1));
  });

  test('an override written live is honored on the next turn', () async {
    int? override; // no written value: window-derived
    final provider = ScriptedProvider([
      turn('a' * 400000), // ~100K
      turn('b' * 400000), // ~200K: under the 1M-window trigger
      turn('ok'), // the turn after the settings write
      scriptedReply('summary'),
    ]);
    final host = hostWith(
        provider,
        CompactionPlugin(
          readContextWindow: () => 1000000,
          readThresholdOverride: () => override,
        ));
    await host.send('one');
    await host.send('two');
    expect(provider.callCount, 2);
    override = 1000; // the settings write
    await host.send('three');
    expect(provider.callCount, 4);
    expect(host.session.loop.log.whereType<CompactedEntry>(), hasLength(1));
  });

  test('an unknown window keeps the safe 100K default — still enabled',
      () async {
    final provider = ScriptedProvider([
      turn('a' * 200000), // ~50K: under the fallback
      turn('b' * 240000), // ~110K total: over the fallback
      scriptedReply('summary'),
    ]);
    final host =
        hostWith(provider, CompactionPlugin(readContextWindow: () => null));
    await host.send('one');
    expect(provider.callCount, 1);
    expect(host.session.loop.log.whereType<CompactedEntry>(), isEmpty);
    await host.send('two');
    expect(provider.callCount, 3,
        reason: 'the fallback trigger fires — never silently disabled');
    expect(host.session.loop.log.whereType<CompactedEntry>(), hasLength(1));
  });

  test('no seams at all keeps the historical fixed default', () async {
    final provider = ScriptedProvider([
      turn('a' * 200000), // ~50K
      turn('b' * 240000), // ~110K: over the 100K default
      scriptedReply('summary'),
    ]);
    final host = hostWith(provider, CompactionPlugin());
    await host.send('one');
    await host.send('two');
    expect(provider.callCount, 3);
    expect(host.session.loop.log.whereType<CompactedEntry>(), hasLength(1));
  });

  test('the kept-recent tail scales with the window', () async {
    // A 1M window keeps a 100K-token tail. The crossing turn's exchange
    // is ~60K tokens — it FITS the scaled tail (the historical 15K floor
    // could never keep it). Older history: ~50K + ~700K. Total ~810K,
    // over the 800K trigger. The budget swallows the newest exchange,
    // stops inside the 700K one, and the turn-boundary snap keeps only
    // the newest exchange verbatim — the 700K exchange is summarized
    // despite its size, while the 60K recent work survives.
    final provider = ScriptedProvider([
      turn('a' * 200000), // ~50K tokens
      turn('b' * 2800000), // ~700K tokens
      turn('c' * 240000), // ~60K tokens: ~810K total, over the trigger
      scriptedReply('summary of the old exchanges'),
    ]);
    final host = hostWith(
        provider, CompactionPlugin(readContextWindow: () => 1000000));
    await host.send('one');
    await host.send('two');
    expect(host.session.loop.log.whereType<CompactedEntry>(), isEmpty);
    await host.send('three');
    await settle();
    final compacted =
        host.session.loop.log.whereType<CompactedEntry>().toList();
    expect(compacted, hasLength(1));
    // The two older exchanges (derived positions 0..3) were summarized;
    // the newest exchange stays verbatim beside the summary.
    expect(compacted.single.replacedFrom, 0);
    expect(compacted.single.replacedTo, 3);
    final messages = host.session.loop.derive().messages;
    expect(messages, hasLength(3));
    expect(messages[0].content.whereType<TextBlock>().single.text,
        '${compactionSummaryMarker}summary of the old exchanges');
    expect(messages[1].content.whereType<TextBlock>().single.text, 'three');
    expect(messages[2].content.whereType<TextBlock>().single.text,
        'c' * 240000);
  });

  test('the historical 15K floor cannot keep the same recent exchange',
      () async {
    // The SAME transcript as the scaled-tail test, but with the
    // historical fixed configuration (explicit 100K threshold, 15K
    // tail — the pre-window defaults). The newest exchange (~60K)
    // exceeds the 15K tail, so rule 4 summarizes EVERYTHING — nothing
    // stays verbatim. The scaled tail above kept it; the floor cannot.
    // This is the regression the window-derived tail fixes.
    final provider = ScriptedProvider([
      turn('a' * 40000), // ~10K tokens
      turn('b' * 40000), // ~10K tokens: ~20K, under the explicit trigger
      turn('c' * 240000), // ~60K tokens: ~80K total, over the trigger
      scriptedReply('summary of everything'),
    ]);
    final host = hostWith(
        provider,
        CompactionPlugin(
          readContextWindow: () => 1000000,
          config: const CompactionConfig(
              thresholdTokens: 50000, keepRecentTokens: 15000),
        ));
    await host.send('one');
    await host.send('two');
    await host.send('three');
    await settle();
    final compacted =
        host.session.loop.log.whereType<CompactedEntry>().toList();
    expect(compacted, hasLength(1));
    expect(compacted.single.replacedFrom, 0);
    expect(compacted.single.replacedTo, 5,
        reason: 'the newest exchange alone exceeds the 15K floor');
    final messages = host.session.loop.derive().messages;
    expect(messages, hasLength(1));
    expect(messages[0].content.whereType<TextBlock>().single.text,
        '${compactionSummaryMarker}summary of everything');
  });

  test('an explicit config keeps its fixed semantics (no window scaling)',
      () async {
    // The historical caller shape: explicit threshold and tail. Even a
    // 1M window must not move them.
    final provider = ScriptedProvider([
      turn('x' * 400),
      turn('y' * 400),
      scriptedReply('summary'),
    ]);
    final host = hostWith(
        provider,
        CompactionPlugin(
          readContextWindow: () => 1000000,
          config: const CompactionConfig(
              thresholdTokens: 100, keepRecentTokens: 100),
        ));
    await host.send('one');
    await host.send('two');
    expect(provider.callCount, 3);
    expect(host.session.loop.log.whereType<CompactedEntry>(), hasLength(1));
  });

  test('an explicit 0 config disables even with a window and no override',
      () async {
    final provider = ScriptedProvider([
      turn('a' * 400000),
      turn('b' * 400000),
    ]);
    final host = hostWith(
        provider,
        CompactionPlugin(
          readContextWindow: () => 65000,
          config: const CompactionConfig(thresholdTokens: 0),
        ));
    await host.send('one');
    await host.send('two');
    expect(provider.callCount, 2);
    expect(host.session.loop.log.whereType<CompactedEntry>(), isEmpty);
  });
}
