import 'dart:async';

import '../runtime/plugin.dart';
import '../tools/execution_request.dart';
import 'tool_hooks.dart';

/// Read-only dispatch evidence. A check cannot execute or replace the tool.
/// [execution] is the prepared process request, when this is a process tool.
final class ToolCheckContext extends ToolCallContext {
  final ExecutionRequest? execution;
  final bool outsideSandbox;
  final Future<void> cancelSignal;
  const ToolCheckContext({
    required super.toolName,
    required super.toolId,
    required super.input,
    required super.isCancelled,
    required this.cancelSignal,
    required this.outsideSandbox,
    this.execution,
  });
}

/// Optional, awaited check immediately before dispatch (including retries).
/// Null permits proceeding to the mandatory permission/phase guards. A string
/// blocks this call with that explanation. Unknown classifier results must be
/// mapped explicitly by the implementing policy; they are not implicit passes.
/// Exceptions and timeouts block. No implementation is installed by default.
abstract class ToolCheck {
  String get id;

  /// Rechecked after all waits, immediately before dispatch.
  bool get isAvailable => true;
  Duration get timeout => const Duration(seconds: 30);
  Future<String?> check(ToolCheckContext context);
}

List<ToolCheck> toolChecksFromScope(PluginScope scope) => [
      for (final entry in scope.contributions)
        if (entry.contribution is ToolCheck)
          _ScopedCheck(scope, entry, entry.contribution as ToolCheck),
    ];

// A mounted check is a binding, not a permanent copy of a plugin. If it is
// removed while a call is waiting, that call must not dispatch on stale policy.
class _ScopedCheck extends ToolCheck {
  final PluginScope scope;
  final Contribution entry;
  final ToolCheck delegate;
  _ScopedCheck(this.scope, this.entry, this.delegate);
  bool get live => scope.isAdmitting && scope.contributions.contains(entry);
  @override
  bool get isAvailable => live && delegate.isAvailable;
  @override
  String get id => delegate.id;
  @override
  Duration get timeout => delegate.timeout;
  @override
  Future<String?> check(ToolCheckContext context) async {
    if (!live) return 'Tool check $id was removed; retry with current policy.';
    final removed = Completer<String?>();
    final subscription = scope.changes.listen((_) {
      if (!live && !removed.isCompleted) {
        removed
            .complete('Tool check $id was removed; retry with current policy.');
      }
    });
    try {
      final result = await Future.any([
        Future.sync(() => delegate.check(context)),
        removed.future,
        context.cancelSignal.then((_) => 'Tool check $id cancelled.'),
      ]);
      return live
          ? result
          : 'Tool check $id was removed; retry with current policy.';
    } finally {
      await subscription.cancel();
    }
  }
}

/// Each check gets a bounded lifetime, even if a plugin ignores cancellation.
/// The stop signal also completes on timeout or completion so cooperative
/// implementations can clean up their own requests. Late results are ignored.
Future<String?> runToolChecks(
  List<ToolCheck> checks,
  ToolCallContext call, {
  Future<void>? cancelSignal,
  ExecutionRequest? execution,
  required bool outsideSandbox,
}) async {
  for (final check in checks) {
    final stop = Completer<void>();
    var cancelled = false;
    void cancel() {
      if (stop.isCompleted) return;
      cancelled = true;
      stop.complete();
    }

    cancelSignal?.then((_) => cancel(), onError: (Object _) => cancel());
    try {
      // Observe already completed cancellation before invoking plugin code.
      await Future<void>.value();
      if (cancelled || call.isCancelled()) return 'Cancelled before execution';
      if (!check.isAvailable) return 'Tool check ${check.id} is unavailable.';
      if (check.timeout <= Duration.zero) return 'Invalid tool check timeout';
      final result = await Future.any<String?>([
        Future.sync(() => check.check(ToolCheckContext(
              toolName: call.toolName,
              toolId: call.toolId,
              input: call.input,
              isCancelled: () => stop.isCompleted || call.isCancelled(),
              cancelSignal: stop.future,
              execution: execution,
              outsideSandbox: outsideSandbox,
            ))),
        stop.future.then((_) => 'Cancelled before execution'),
      ]).timeout(check.timeout);
      if (cancelled || call.isCancelled()) return 'Cancelled before execution';
      if (result != null) return result;
    } on TimeoutException {
      return 'Tool check ${check.id} timed out; execution blocked.';
    } catch (_) {
      return 'Tool check ${check.id} failed; execution blocked.';
    } finally {
      if (!stop.isCompleted) stop.complete();
    }
  }
  return null;
}
