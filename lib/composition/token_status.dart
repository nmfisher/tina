import 'package:tina_app/tina_app.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';
import '../tui/token_status_renderer.dart';
import '../tui/status_layout_plugin.dart';

/// Mounts the live token-spend display on the status strip beneath the input.
///
/// Three contributions:
/// - the [LedgerTokenStatusSource] (a [StatusSource] snapshotting the
///   conversation-wide spend ledger on its `changes` stream),
/// - the [TokenUsageRenderer] (a [Renderer] of [TokenUsageSummary], painted
///   right-aligned on the strip),
/// - a [PriorityStatusLayout] (a [StatusLayout]) that keeps the token counter
///   visible under width pressure by dropping lower-priority left lines
///   before the right group, then trimming the counter itself.
///
/// Layout note: the strip supports at most ONE right-aligned group; the first
/// right-aligned line rendered wins the row's tail. With this plugin mounted,
/// the token counter owns that slot.
PluginDescriptor tokenStatusPlugin() => PluginDescriptor(
  id: 'tina.token-status',
  requires: {spendLedgerServiceKey},
  factory: FnPluginFactory((context) {
    final ledger = context.require(spendLedgerServiceKey);
    context.register(
      LedgerTokenStatusSource(ledger),
      id: 'tina.token-status.source',
    );
    context.register(
      const TokenUsageRenderer(),
      id: 'tina.token-status.renderer',
    );
    context.register(
      const PriorityStatusLayout(),
      id: 'tina.status-layout.priority',
    );
    return Object();
  }),
);
