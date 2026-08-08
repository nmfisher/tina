import '../agent/agent_pipeline.dart';
import '../agent/sub_agent_scheduler.dart';
import 'audit.dart';
import 'tool.dart';

/// Hard-coded per-call delegate fanout cap. A single `delegate` invocation may
/// spawn at most this many sub-agents; the model retries in batches. No config
/// surface by design. Bounds one call, not the run's total sub-agent count
/// (that larger bound is a follow-up — review M1).
const int kMaxDelegations = 8;

/// One parsed delegation: the sub-agent's task (its identity for the run, on
/// top of the parent's system prompt), its tool profile, and an optional model
/// override. A `null` [modelReference] inherits the conversation's model.
class Delegation {
  final String task;
  final ToolProfile toolProfile;
  final String? modelReference;

  /// A short label for the merged result (derived from the task).
  final String label;

  const Delegation({
    required this.task,
    required this.toolProfile,
    required this.label,
    this.modelReference,
  });
}

/// Shared scaffolding for tools that spawn sub-agents from a `delegations`
/// array. Parses the same `{task, tools?, llm_model?, llm_provider?}` entries
/// and calls `scheduler.spawn` with the same context block. A sub-agent
/// inherits the parent's resolved system prompt ([AgentToolContext.parentSystemPrompt])
/// plus the delegation's [Delegation.task]; its tools come from the profile.
///
/// Holds an [AgentToolContext] rather than the fields individually, so the
/// wiring threads one object and nesting/depth/identity stay consistent.
abstract class DelegationToolBase implements Tool {
  final AgentToolContext ctx;
  DelegationToolBase(this.ctx);

  SubAgentScheduler get scheduler => ctx.scheduler;
  AgentPipeline get pipeline => ctx.pipeline;

  /// The tool's schema name ('delegate', …).
  String get toolName;

  /// One-line lead for the description, e.g. 'Delegate to sub-agents and return
  /// their merged answers. …'.
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
                  'task': {
                    'type': 'string',
                    'description': 'The task for the sub-agent. It runs under '
                        'your identity plus this task.',
                  },
                  'tools': {
                    'type': 'string',
                    'enum': ['read-only', 'full'],
                    'description': 'Tool profile. "read-only" (default): read/'
                        'explore only, no file or shell mutation — safe for '
                        'research and review. "full": also write, edit, and run '
                        'shell. Omit for read-only.',
                  },
                  'llm_provider': {
                    'type': 'string',
                    'description': 'Provider id for this sub-agent, e.g. '
                        '"anthropic". Omit (with llm_model) to inherit the '
                        'conversation model.',
                  },
                  'llm_model': {
                    'type': 'string',
                    'description': 'Model id for this sub-agent, e.g. '
                        '"claude-sonnet-4-6". Omit (with llm_provider) to '
                        'inherit the conversation model.',
                  },
                },
                'required': ['task'],
              },
            },
          },
          'required': ['delegations'],
        },
      );

  /// Formats the description lead plus a note on the profiles + model override.
  String describe(String lead) {
    return '$lead\nEach delegation is an object: `task` (required), optional '
        '`tools` ("read-only" default, or "full"), and optional `llm_provider` '
        '+ `llm_model` to run it on a different model.';
  }

  /// Parses + validates the `delegations` array. Returns the parsed
  /// delegations, or an error message (keyed by [toolName]) the caller should
  /// surface as a [ToolResult.error]. `null` error means success.
  ({List<Delegation> delegations, String? error}) resolve(
      Map<String, dynamic> input) {
    final list = (input['delegations'] as List?) ?? const [];
    // Per-call fanout cap (review M1): a single `delegate` invocation may spawn
    // at most [kMaxDelegations] sub-agents. The model retries in batches.
    // Audited for forensics. This bounds one call, not the run's total sub-agent
    // count (a run-scoped total is a documented follow-up).
    if (list.length > kMaxDelegations) {
      auditDenial(kind: auditFanout, detail: '${list.length} delegations');
      return (
        delegations: const [],
        error: '$toolName: too many delegations (${list.length}). '
            'Maximum per call is $kMaxDelegations — split into batches.',
      );
    }
    final delegations = <Delegation>[];
    for (final d in list) {
      final m = d as Map<String, dynamic>;
      final task = (m['task'] as String?) ?? '';
      if (task.trim().isEmpty) {
        return (
          delegations: const [],
          error: '$toolName: every delegation needs a non-empty `task`.',
        );
      }
      final profile = parseToolProfile(m['tools'] as String?);
      final provider = (m['llm_provider'] as String?)?.trim();
      final model = (m['llm_model'] as String?)?.trim();
      // A model override needs both halves; either alone is a partial spec and
      // is ignored (falling back to the inherited model) rather than guessing.
      final modelReference =
          (provider != null && provider.isNotEmpty && model != null && model.isNotEmpty)
              ? '$provider/$model'
              : null;
      delegations.add(Delegation(
        task: task,
        toolProfile: profile,
        modelReference: modelReference,
        label: _labelFor(task),
      ));
    }
    if (delegations.isEmpty) {
      return (delegations: const [], error: '$toolName: no delegations given');
    }
    return (delegations: delegations, error: null);
  }

  /// Spawns one job per delegation on the context's scheduler, returning them
  /// in order. Shared by every delegation tool.
  List<SubAgentJob> spawnAll(List<Delegation> delegations) {
    return delegations
        .map((d) => scheduler.spawn(
              task: d.task,
              toolProfile: d.toolProfile,
              modelReference: d.modelReference,
              parentSystemPrompt: ctx.parentSystemPrompt,
              parentReference: ctx.parentReference,
              parentPolicy: ctx.parentPolicy,
              originConversationId: ctx.originConversationId,
              depth: ctx.depth,
              label: d.label,
            ))
        .toList();
  }
}

/// Derive a short label from a task's first line, for the merged result header.
String _labelFor(String task) {
  final line = task.split('\n').firstWhere((l) => l.trim().isNotEmpty,
      orElse: () => task.trim());
  const cap = 60;
  final trimmed = line.trim();
  return trimmed.length <= cap ? trimmed : '${trimmed.substring(0, cap)}…';
}
