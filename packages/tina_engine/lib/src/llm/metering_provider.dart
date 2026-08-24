import 'dart:async';

import '../agent/pause_gate.dart';
import '../agent/spend_ledger.dart';
import '../tools/tool.dart';
import 'message.dart';
import 'provider.dart';
import 'wire.dart';

/// #46 funnel: live-instance tracking avoids closing one ephemeral
/// [MeteringProvider] (e.g. a summary/env runner's) from nulling the hook
/// another live instance still relies on. Each instance installs itself
/// as the active handler on the shared [Wire] slot; [close()] only
/// reinstalls the newest remaining live handler (or nulls when none).
/// All instances route to their shared ledger, so reports never double-book.
final List<MeteringProvider> _liveMeters = <MeteringProvider>[];

/// A pass-through [LlmProvider] decorator that is the single funnel for spend
/// metering and rate-limiting. Applied once inside `ProviderRegistry.build`, it
/// therefore wraps every provider the app constructs — the startup provider, the
/// per-conversation providers (`/session new`, `/model`), and every sub-agent's
/// provider — so even requests that bypass the per-agent [TokenBudget]
/// (e.g. `Agent.compact`, which calls `provider.send` directly) are counted.
///
/// On each [send]:
/// - If the ledger is already tripped (global token ceiling crossed), emits a
///   single [StreamError] carrying [SpendLimitExceeded] and never subscribes to
///   the inner provider — the agent's stream consumer surfaces that as a turn
///   error and the turn aborts with no wire traffic.
/// - Otherwise awaits one RPM slot from the ledger (no-op when the throttle is
///   disabled).
/// - Re-checks the trip after the throttle (a request that finished while
///   another tripped the ceiling is refused before hitting the wire).
/// - Forwards the inner stream, recording `MessageComplete.usage` to the ledger.
///
/// The stream is [StreamController]-backed (not `async*`) so that cancelling the
/// subscription mid-throttle — i.e. the user pressing ESC during an RPM wait —
/// tears things down promptly: `onCancel` cancels the inner subscription and
/// aborts the blocked slot acquire within one throttle tick. An `async*`
/// generator parked on a plain await would hang on cancel (see the `_HoldProvider`
/// note in `sub_agent_scheduler_test.dart`), which is unacceptable when the
/// throttle wait can be up to a minute.
class MeteringProvider implements LlmProvider {
  final LlmProvider inner;
  final SpendLedger ledger;

  /// When set, every [send] awaits the gate before doing anything — that's how
  /// a per-session-limit trip in one agent pauses ALL agents (each one blocks
  /// here at its next request). Null in tests / headless (no pause behavior).
  final PauseGate? pauseGate;

  MeteringProvider(this.inner, this.ledger, [this.pauseGate]) {
    // #46: funnel for retried-spend reports from both failure ladders.
    // Each attempt's invisible cost (estimate or measured error usage) flows
    // through here into the ledger. Every instance over the same shared
    // session ledger routes its reports to that one ledger, so a report is
    // booked exactly once no matter how many meters are alive; the static
    // slot always points at the newest live instance (see [_liveMeters]).
    _liveMeters.add(this);
    Wire.onAttemptUsage = _recordAttemptUsage;
  }

  void _recordAttemptUsage(AttemptUsage usage) {
    final t = TokenUsage(
      inputTokens: usage.usage.inputTokens,
      outputTokens: usage.usage.outputTokens,
      cacheCreationInputTokens: usage.usage.cacheCreationInputTokens,
      cacheReadInputTokens: usage.usage.cacheReadInputTokens,
    );
    // One entry point books everything: the measured/estimated counters AND
    // the retried tallies that drive the #46 (c) degrading-provider notice.
    ledger.recordRetried(t, estimated: usage.estimated);
  }

  @override
  void close() {
    // Only stop funneling when this is the last live meter — an earlier
    // ephemeral runner's close() must not kill the hook the session's
    // remaining meters still rely on.
    _liveMeters.remove(this);
    Wire.onAttemptUsage =
        _liveMeters.isEmpty ? null : _liveMeters.last._recordAttemptUsage;
    inner.close();
  }

  /// Delegate so `/model <name>` (which assigns `provider.model = next`) reaches
  /// the real underlying provider rather than a dead field on the decorator.
  @override
  String get model => inner.model;
  @override
  set model(String value) {
    inner.model = value;
  }

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) {
    late StreamController<StreamEvent> controller;
    StreamSubscription<StreamEvent>? innerSub;
    // Completed by `onCancel` so a blocked RPM acquire aborts (the acquire races
    // its wait against this future) and any inner subscription is torn down.
    final cancelCompleter = Completer<void>();

    void emitTripped() {
      if (controller.isClosed) return;
      controller.add(StreamError(SpendLimitExceeded(
          ledger.reason ?? 'global token spend limit exceeded')));
    }

    Future<void> run() async {
      // Pause gate: when any agent trips its per-session limit this gate closes,
      // parking every agent at its next request. Checked first (before the spend
      // ceiling and the RPM slot) so a paused agent doesn't consume an RPM token
      // while waiting. Cancel-safe — races the same cancelCompleter used for
      // RPM-cancel, so ESC tearing down a paused provider returns promptly.
      if (pauseGate != null) {
        final ok = await pauseGate!.waitForResume(
            cancelSignal: cancelCompleter.future);
        if (!ok || cancelCompleter.isCompleted) return; // cancelled mid-pause
      }
      if (ledger.tripped) {
        emitTripped();
        await controller.close();
        return;
      }
      final granted = await ledger.acquireRequestSlot(
          cancelSignal: cancelCompleter.future);
      // `!granted` ⇒ cancelled mid-throttle; `cancelCompleter` completed ⇒
      // cancelled the instant a slot was granted. Either way, never subscribe.
      if (!granted || cancelCompleter.isCompleted) return;
      if (ledger.tripped) {
        emitTripped();
        await controller.close();
        return;
      }
      innerSub = inner
          .send(system: system, messages: messages, tools: tools)
          .listen(
            (event) {
              if (controller.isClosed) return;
              if (event is MessageComplete && event.usage != null) {
                ledger.record(event.usage!);
              }
              controller.add(event);
            },
            onError: (Object e, StackTrace st) {
              if (!controller.isClosed) controller.addError(e, st);
            },
            onDone: () {
              if (!controller.isClosed) controller.close();
            },
          );
    }

    controller = StreamController<StreamEvent>(
      onListen: () => unawaited(run()),
      onCancel: () {
        if (!cancelCompleter.isCompleted) cancelCompleter.complete();
        return innerSub?.cancel();
      },
    );
    return controller.stream;
  }
}
