import 'dart:async';

import '../agent/sub_agent_scheduler.dart';
import 'delegation_base.dart';
import 'tool.dart';

/// The orchestrator's await-driven delegation tool. Spawns one sub-agent per
/// entry, awaits them all (yielding on the event loop, so other detached jobs
/// keep progressing), and merges their final answers into one [ToolResult].
///
/// The orchestrator never holds scheduler/job references beyond this call —
/// `delegate` is the whole main→sub channel, which keeps the agent loop, the
/// permission gate, and the result flow identical to any other tool. A main-turn
/// cancel ([cancelSignal]) propagates to every spawned job.
///
/// Live progress still flows while awaiting: the jobs emit on their buses and
/// the TUI renders `«{label}: → …»`, so this is not a silent block.
///
/// Inherits its schema, delegation parsing, and spawn block from
/// [DelegationToolBase]; only the post-spawn await + merge is specific here.
class DelegateTool extends DelegationToolBase {
  DelegateTool(AgentToolContext ctx) : super(ctx);

  @override
  String get toolName => 'delegate';

  @override
  String get toolDescriptionLead => 'Delegate to sub-agents and return their '
      'merged answers. Each delegation runs concurrently.';

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final resolved = resolve(input);
    final error = resolved.error;
    if (error != null) return ToolResult.error(error);

    final jobs = spawnAll(resolved.delegations);

    // A main-turn cancel tears down every spawned job; their results then
    // complete and Future.wait resolves.
    cancelSignal?.whenComplete(() {
      for (final j in jobs) {
        j.cancel();
      }
    });

    final results = await Future.wait(jobs.map((j) => j.result));
    final parts = <String>[];
    for (var i = 0; i < resolved.delegations.length; i++) {
      final r = results[i];
      parts.add('### ${resolved.delegations[i].label}\n${r.content}'
          '${r.isError ? "\n(error)" : ""}');
    }
    return ToolResult(parts.join('\n\n'),
        isError: results.any((r) => r.isError));
  }
}

/// Returns a new registry with a [DelegateTool] appended, configured for a
/// parent agent by [ctx]. The wiring calls this to give the main agent the
/// spawn tool (and the nesting builder calls [DelegateTool] directly).
ToolRegistry withDelegateTool(ToolRegistry base, AgentToolContext ctx) {
  return ToolRegistry([...base.all, DelegateTool(ctx)]);
}
