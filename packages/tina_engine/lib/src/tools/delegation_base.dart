import '../agent/agent_pipeline.dart';
import '../agent/sub_agent_scheduler.dart';
import '../agent/workflow.dart';
import 'audit.dart';
import 'tool.dart';

/// Hard-coded per-call delegate fanout cap. A single `delegate`/`dispatch`
/// invocation may spawn at most this many sub-agents; the model retries in
/// batches. No config surface by design. Bounds one call, not the run's total
/// sub-agent count (that larger bound is a follow-up — review M1).
const int kMaxDelegations = 8;

/// Shared scaffolding for tools that spawn sub-agents from a `delegations`
/// array (`delegate`, `dispatch`). Both parse the same `{agent, task}` entries
/// against the same pipeline, expose the same schema (modulo name/description),
/// and call `scheduler.spawn` with the same context block. Subclasses implement
/// only [execute] — the post-spawn behavior is what differs (await + merge vs
/// return handles).
///
/// Holds an [AgentToolContext] rather than the fields individually, so the
/// wiring threads one object and nesting/depth stay consistent across tools.
abstract class DelegationToolBase implements Tool {
  final AgentToolContext ctx;
  DelegationToolBase(this.ctx);

  SubAgentScheduler get scheduler => ctx.scheduler;
  AgentPipeline get pipeline => ctx.pipeline;

  /// The tool's schema name ('delegate', 'dispatch', …).
  String get toolName;

  /// One-line lead for the description, e.g. 'Delegate to sub-agents and return
  /// their merged answers. …'. [describe] appends the pipeline listing.
  String get toolDescriptionLead;

  @override
  ToolSchema get schema => ToolSchema(
        name: toolName,
        description: describe(toolDescriptionLead),
        inputSchema: {
          'type': 'object',
          'properties': {
            'delegations': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'agent': {
                    'type': 'string',
                    'enum': pipeline.delegateTargets
                        .map((s) => s.name)
                        .toList(),
                    'description':
                        'Which sub-agent to run (see available agents above).',
                  },
                  'task': {
                    'type': 'string',
                    'description': 'The task for the sub-agent.',
                  },
                },
                'required': ['agent', 'task'],
              },
            },
          },
          'required': ['delegations'],
        },
      );

  /// Formats the description lead plus the pipeline listing (or a fallback when
  /// the pipeline has no delegatable targets).
  String describe(String lead) {
    final targets = pipeline.delegateTargets;
    if (targets.isEmpty) return '$lead (no agents available).';
    final agents = targets.map((s) => '  - "${s.name}": ${s.description}').join('\n');
    return '$lead\nAvailable agents:\n$agents';
  }

  /// Parses + validates the `delegations` array. Returns the resolved targets,
  /// or an error message (keyed by [toolName]) the caller should surface as a
  /// [ToolResult.error]. `null` error means success.
  ({List<(String, String, DelegationTarget)> targets, String? error}) resolve(
      Map<String, dynamic> input) {
    final list = (input['delegations'] as List?) ?? const [];
    // Per-call fanout cap (review M1): a single `delegate`/`dispatch` invocation
    // may spawn at most [kMaxDelegations] sub-agents. The model retries in
    // batches. Audited for forensics. This bounds one call, not the run's total
    // sub-agent count (a run-scoped total is a documented follow-up).
    if (list.length > kMaxDelegations) {
      auditDenial(kind: auditFanout, detail: '${list.length} delegations');
      return (
        targets: const [],
        error: '$toolName: too many delegations (${list.length}). '
            'Maximum per call is $kMaxDelegations — split into batches.',
      );
    }
    final targets = <(String, String, DelegationTarget)>[];
    for (final d in list) {
      final m = d as Map<String, dynamic>;
      final name = (m['agent'] as String?) ?? '';
      final task = (m['task'] as String?) ?? '';
      final target = pipeline.target(name);
      if (target == null) {
        return (
          targets: const [],
          error: '$toolName: unknown agent "$name". Known: '
              '${pipeline.delegateTargets.map((s) => s.name).join(", ")}',
        );
      }
      targets.add((name, task, target));
    }
    if (targets.isEmpty) {
      return (targets: const [], error: '$toolName: no delegations given');
    }
    return (targets: targets, error: null);
  }

  /// Spawns one job per target on the context's scheduler, returning them in
  /// order. Shared verbatim by `delegate` and `dispatch`; neither overrides it.
  List<SubAgentJob> spawnAll(List<(String, String, DelegationTarget)> targets) {
    return targets
        .map((e) => scheduler.spawn(
              target: e.$3,
              task: e.$2,
              parentReference: ctx.parentReference,
              parentPolicy: ctx.parentPolicy,
              originConversationId: ctx.originConversationId,
              depth: ctx.depth,
            ))
        .toList();
  }
}
