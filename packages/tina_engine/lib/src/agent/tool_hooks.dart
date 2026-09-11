import '../runtime/plugin.dart';
import '../tools/tool.dart';

/// What a tool hook may see about ONE tool call. Deliberately narrow: the
/// tool name and id (for correlation with the sink/observer events), the
/// execution input the tool will run with, and a read-only cancellation
/// probe. It does NOT expose the cancel signal itself, the tool instance, or
/// the [AgentSink] — a hook can observe and wrap the call, but by
/// construction it cannot swap the tool, rewrite the arguments, detach the
/// cancellation wiring, or reroute output.
class ToolCallContext {
  /// Name of the tool being dispatched (e.g. `bash`).
  final String toolName;

  /// The model's tool_use id for this call — the same id the result block
  /// carries back.
  final String toolId;

  /// The input the tool will actually execute with (after the executor's
  /// sandbox-retry input merge, when one applied).
  ///
  /// A deeply UNMODIFIABLE view of the executor's private execution
  /// snapshot: a hook can read every argument, but a mutation attempt —
  /// top-level or nested — throws, so the authorized arguments are the ones
  /// that run (the executor's delegation seal, tool_executor.dart).
  final Map<String, dynamic> input;

  /// Whether the run is currently cancelled. A probe, not a signal: hooks
  /// can consult it, never replace it.
  final bool Function() isCancelled;

  const ToolCallContext({
    required this.toolName,
    required this.toolId,
    required this.input,
    required this.isCancelled,
  });
}

/// An AROUND-EXECUTION hook: awaited around the actual
/// `executionTool.execute(...)` call only — after the guard gates and the
/// dispatch-boundary guard recheck, which stay where they are today
/// (outside the wrapper). Moving the recheck inside the delegate is
/// deliberately deferred until a real preparation hook needs it; today there
/// is no async preparation between recheck and execute, so the order is
/// unobservable.
///
/// A hook runs [delegate] to execute the tool and may wrap the result.
/// Delegation is EXACTLY-ONCE, enforced by the [ToolExecutor]:
///
///  * a second `delegate()` call throws, and the executor converts any hook
///    error into an error tool result — fail closed, even if the hook
///    swallows the throw;
///  * a hook that returns WITHOUT delegating also becomes an error tool
///    result (`hook did not execute the tool`).
///
/// The `delegate` closure captures the tool, the input, the effective cancel
/// signal, and the output routing to the sink — so a hook cannot replace the
/// tool identity or arguments and cannot detach cancellation.
abstract class ToolExecutionHook {
  /// Wraps this call. Call [delegate] exactly once to run the tool; the
  /// returned [ToolResult] is what the executor's post-execution flow sees.
  Future<ToolResult> run(
      ToolCallContext context, Future<ToolResult> Function() delegate);
}

/// A POST-TOOL processing hook: awaited on a SUCCESSFUL (non-error) tool
/// result, in declared order. The FIRST non-null verdict is appended to the
/// result content and the rest are skipped — exactly today's verifier-gate
/// semantics. A hook that throws is logged and processing continues with the
/// content unchanged — exactly today's verifier-crash behavior.
///
/// The legacy `Agent.resultVerifier` is the first hook of this stage (the
/// executor adapts it privately), so it keeps its exact public API and
/// behavior, and any declared [ToolResultHook]s run after it.
abstract class ToolResultHook {
  /// Returns a verdict to append to the tool result (after the tool's own
  /// content, newline-separated), or null for "nothing to add".
  Future<String?> process(
    String toolName,
    Map<String, dynamic> input,
    ToolResult result,
  );
}

/// An OBSERVATION-only hook: sees the same tool events the [AgentSink]
/// receives (start, streamed output, completion), but can never change
/// execution. The [ToolExecutor] contains observer exceptions (catch, log,
/// continue) and the sink calls themselves are untouched — observers are
/// additive. [AgentSink]/BusSink remain the built-in observe-only adapters
/// (rendering and broadcast); a [ToolObserver] is the seam for everything
/// else that wants to watch tool traffic without becoming a sink.
abstract class ToolObserver {
  /// A tool is about to execute (after permission approval) — the same
  /// payload the sink's `toolStart` receives.
  void onToolStart(ToolStartEvent event);

  /// Incremental output from a running tool (e.g. bash stdout/stderr).
  void onToolOutput(ToolOutputEvent event);

  /// A tool finished — success or failure.
  void onToolComplete(ToolCompleteEvent event);
}

/// The scope's [ToolExecutionHook] contributions, in declared registration
/// order — the order the plugins registered them, with no reordering
/// (mirrors [toolGuardsFromScope]).
List<ToolExecutionHook> toolExecutionHooksFromScope(PluginScope scope) => [
      for (final contribution in scope.contributions)
        if (contribution.contribution is ToolExecutionHook)
          contribution.contribution as ToolExecutionHook,
    ];

/// The scope's [ToolResultHook] contributions, in declared registration
/// order — the order the plugins registered them, with no reordering
/// (mirrors [toolGuardsFromScope]).
List<ToolResultHook> toolResultHooksFromScope(PluginScope scope) => [
      for (final contribution in scope.contributions)
        if (contribution.contribution is ToolResultHook)
          contribution.contribution as ToolResultHook,
    ];

/// The scope's [ToolObserver] contributions, in declared registration order —
/// the order the plugins registered them, with no reordering (mirrors
/// [toolGuardsFromScope]).
List<ToolObserver> toolObserversFromScope(PluginScope scope) => [
      for (final contribution in scope.contributions)
        if (contribution.contribution is ToolObserver)
          contribution.contribution as ToolObserver,
    ];
