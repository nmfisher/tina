/// A declaration you can delegate *to* — an `AgentRole` (in `agent_pipeline.dart`)
/// or a [Workflow]. The scheduler builds one or more runtime `Agent`s from it; a
/// [DelegationTarget] is not itself a running agent. It is both the delegate
/// picker interface (the union the schema enum lists) and the scheduler's
/// spawn-target union (`spawn({target})`, `SubAgentJob.target`, the dispatch on
/// `is Workflow` / `is AgentRole`).
abstract class DelegationTarget {
  String get name;
  String get description;
}

/// A named, ordered sequence of stages — the composition counterpart to a role.
/// The scheduler runs each [WorkflowStage] in dependency order (independent
/// stages concurrently), feeding a stage's declared dependencies' outputs
/// forward as `--- prior work ---` context; the workflow's result is the final
/// stage's output. A workflow never builds a provider or runs tools itself — it
/// only orchestrates, so it doesn't hold a concurrency slot (its stages do).
class Workflow implements DelegationTarget {
  @override
  final String name;

  @override
  final String description;

  /// Ordered stages. A stage whose [WorkflowStage.target] is itself a workflow
  /// recurses (embedding), bounded by the scheduler's max depth.
  final List<WorkflowStage> stages;

  const Workflow({
    required this.name,
    required this.description,
    required this.stages,
  });
}

/// One stage of a [Workflow]. [target] is a direct, compile-checked reference to
/// the role or nested workflow this stage runs (not a name); [task] is the
/// instruction. When [haltOnFail] is set, an error result from this stage halts
/// the whole workflow and becomes its result.
class WorkflowStage {
  /// The role (or nested workflow) this stage runs — a symbolic reference, so a
  /// missing target is a compile error, not a runtime lookup.
  final DelegationTarget target;

  /// The task text, prepended to the prior-work context from [dependsOn].
  final String task;

  /// Optional stage identifier, so other stages can reference this one in
  /// [dependsOn]. Defaults to the stage's index as a string ("0", "1", …) when
  /// null, so unnamed stages are referenceable.
  final String? id;

  /// The stage ids whose outputs this stage consumes (its "access list"),
  /// determining both ordering and context:
  /// - **null** (default) → the immediately prior stage (a chain). Stage 0 has
  ///   no prior, so it consumes the workflow's incoming input. This is the
  ///   original linear behavior.
  /// - **empty** → a root: consumes only the workflow input, runs first, in
  ///   parallel with other roots.
  /// - **non-empty** → consumes those stages' outputs (in order) and runs once
  ///   they've all finished. A cycle (or a ref to a stage that never produces)
  ///   is an error. Independent stages run concurrently (bounded by the
  ///   scheduler's `maxConcurrent`).
  final List<String>? dependsOn;

  /// If true, an error result from this stage halts the workflow.
  final bool haltOnFail;

  const WorkflowStage({
    required this.target,
    required this.task,
    this.id,
    this.dependsOn,
    this.haltOnFail = false,
  });
}
