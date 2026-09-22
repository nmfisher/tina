import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:tina_engine/invocation.dart' as engine show Invocation;

enum InterruptResult { accepted, declined, cancelled, unavailable }

class InterruptReason {
  final String sourceId;
  final String sourceName;
  const InterruptReason(this.sourceId, this.sourceName);
  @override
  String toString() => 'Interrupted by $sourceName ($sourceId)';
}

class InterruptPrompt {
  final engine.Invocation source;
  final engine.Invocation target;
  final String title;
  final String message;
  final Future<void> cancelSignal;
  const InterruptPrompt(
    this.source,
    this.target,
    this.title,
    this.message,
    this.cancelSignal,
  );
}

typedef InterruptPresenter = Future<bool?> Function(InterruptPrompt prompt);

/// One decision at a time per conversation. Output and dispatch are held by
/// the engine; this service coordinates the user decision and queue handoff.
class Interrupts {
  final Invocations invocations;
  InterruptPresenter? presenter;
  final _tails = <String, Future<void>>{};
  final _requests = <Completer<void>, String>{};
  bool _closed = false;
  Interrupts(this.invocations);

  /// Prevent admission of the next user instruction until a decision and its
  /// accepted action have settled. This never consumes or clears user input.
  Future<void> ready(String conversationId) async {
    while (_tails.containsKey(conversationId)) {
      await _tails[conversationId];
    }
  }

  /// [onAccepted] owns the handoff interval. Put replacement work here so the
  /// conversation queue cannot start its next instruction in the gap.
  Future<InterruptResult> ask({
    required engine.Invocation source,
    required engine.Invocation target,
    required String title,
    String message = '',
    Future<void> Function()? onAccepted,
  }) async {
    if (_closed || presenter == null) return InterruptResult.unavailable;
    if (source.owner != invocations ||
        target.owner != invocations ||
        source.conversationId != target.conversationId ||
        source == target) {
      throw ArgumentError(
        'Interruption requires distinct invocations in the same conversation',
      );
    }
    if (onAccepted != null && InvocationContext.current?.invocation != source) {
      throw ArgumentError(
        'An accepted action must be requested from its source invocation',
      );
    }
    // Holding an ancestor would hold the source too; accepting would join it.
    for (var parent = source.parent; parent != null; parent = parent.parent) {
      if (parent == target) throw ArgumentError('Cannot interrupt an ancestor');
    }
    final id = target.conversationId;
    final previous = _tails[id];
    final finished = Completer<void>();
    final stop = Completer<void>();
    _requests[stop] = id;
    _tails[id] = finished.future;
    var active = true;
    void cancel() {
      if (active && !stop.isCompleted) stop.complete();
    }

    final detachSource = source.listen(() {
      if (source.isCancelled || source.isDone) cancel();
    });
    final detachTarget = target.listen(() {
      if (target.isCancelled || target.isDone) cancel();
    });
    Registration? hold;
    try {
      if (source.isDone ||
          source.isCancelled ||
          target.isDone ||
          target.isCancelled) {
        return InterruptResult.cancelled;
      }
      if (previous != null) {
        await Future.any([previous, stop.future]);
      }
      if (stop.isCompleted || _closed) return InterruptResult.cancelled;
      final show = presenter;
      if (show == null) return InterruptResult.unavailable;
      hold = target.hold();
      if (stop.isCompleted) return InterruptResult.cancelled;
      final decision = await Future.any<bool?>([
        Future.sync(
          () => show(
            InterruptPrompt(source, target, title, message, stop.future),
          ),
        ),
        stop.future.then((_) => null),
      ]);
      if (stop.isCompleted || decision == null)
        return InterruptResult.cancelled;
      if (!decision) return InterruptResult.declined;
      // Target cancellation below is deliberate; do not mistake its signal
      // for withdrawal of the accepted handoff.
      detachTarget();
      target.cancel(InterruptReason(source.id, source.component.name));
      await Future.any([target.done, stop.future]);
      if (stop.isCompleted || source.isCancelled)
        return InterruptResult.cancelled;
      if (onAccepted != null) {
        while (source.isHeld && !source.isCancelled && !stop.isCompleted) {
          await Future.any([source.ready(), stop.future]);
        }
        if (stop.isCompleted || source.isCancelled || source.isDone)
          return InterruptResult.cancelled;
        await Future.any<void>([Future.sync(onAccepted), stop.future]);
        if (stop.isCompleted || source.isCancelled)
          return InterruptResult.cancelled;
      }
      return InterruptResult.accepted;
    } on InvocationCancelled {
      return InterruptResult.cancelled;
    } finally {
      active = false;
      detachSource();
      detachTarget();
      if (!stop.isCompleted) stop.complete();
      await hold?.dispose();
      _requests.remove(stop);
      // Preserve FIFO even when a queued request is cancelled early.
      if (previous != null) await previous;
      if (identical(_tails[id], finished.future)) _tails.remove(id);
      finished.complete();
    }
  }

  void cancelAll({String? conversationId}) {
    for (final entry in _requests.entries.toList()) {
      if ((conversationId == null || entry.value == conversationId) &&
          !entry.key.isCompleted) {
        entry.key.complete();
      }
    }
  }

  void dispose() {
    _closed = true;
    presenter = null;
    cancelAll();
  }
}

const interruptsServiceKey = ServiceKey<Interrupts>('tina.interrupts');

PluginDescriptor invocationPlugin() => PluginDescriptor(
  id: 'tina.invocations',
  provides: [invocationsServiceKey],
  factory: FnPluginFactory((context) {
    final calls = Invocations();
    context.own(calls.dispose);
    return calls;
  }),
);

PluginDescriptor interruptionPlugin() => PluginDescriptor(
  id: 'tina.interrupts',
  requires: {invocationsServiceKey},
  provides: [interruptsServiceKey],
  factory: FnPluginFactory((context) {
    final service = Interrupts(context.require(invocationsServiceKey));
    context.own(service.dispose);
    return service;
  }),
);
