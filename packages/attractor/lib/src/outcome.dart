/// The status a node reaches after its handler runs. Drives routing and the
/// goal-gate check at exit.
enum StageStatus {
  /// Stage completed its work. Proceed to the next edge; reset its retry counter.
  success,

  /// Stage completed with caveats. Treated as success for routing and goal
  /// gates, but [Outcome.notes] describes what was incomplete.
  partialSuccess,

  /// Stage requests re-execution. The engine increments the retry counter and
  /// re-runs the node if within its `max_retries` budget.
  retry,

  /// Stage failed permanently. The engine looks for a fail edge, else
  /// terminates the run.
  fail,

  /// Stage was skipped (e.g. its condition was not met). Proceed without
  /// recording an outcome.
  skipped;

  /// The lowercase wire name used in DOT conditions and `status.json`
  /// (`success`, `partial_success`, `retry`, `fail`, `skipped`).
  String get wire {
    switch (this) {
      case StageStatus.success:
        return 'success';
      case StageStatus.partialSuccess:
        return 'partial_success';
      case StageStatus.retry:
        return 'retry';
      case StageStatus.fail:
        return 'fail';
      case StageStatus.skipped:
        return 'skipped';
    }
  }

  /// Parse a wire name back into a status. Falls back to [fail] for anything
  /// unrecognized so a corrupt status file never reads as success.
  static StageStatus fromWire(String s) {
    switch (s) {
      case 'success':
        return StageStatus.success;
      case 'partial_success':
        return StageStatus.partialSuccess;
      case 'retry':
        return StageStatus.retry;
      case 'fail':
        return StageStatus.fail;
      case 'skipped':
        return StageStatus.skipped;
      default:
        return StageStatus.fail;
    }
  }

  /// Whether this counts as "succeeded" for goal-gate and routing purposes.
  bool get isOk => this == StageStatus.success || this == StageStatus.partialSuccess;
}

/// The result of executing a node handler. The engine applies
/// [contextUpdates], records [status] (and [preferredLabel]) into the run
/// context, then selects the next edge.
class Outcome {
  final StageStatus status;

  /// An edge label to prioritize when selecting the next edge (edge-selection
  /// step 2). Used by human gates (the chosen option) and by autonomous
  /// verdicts (e.g. `approve` / `revise`).
  final String? preferredLabel;

  /// Explicit next node ids, consulted if no condition match and no label match
  /// (edge-selection step 3).
  final List<String> suggestedNextIds;

  /// Key-value pairs merged into the run [Context] after this node completes.
  final Map<String, String> contextUpdates;

  /// Human-readable execution summary, surfaced to the UI and the run log.
  final String notes;

  /// Why the stage failed or is retrying (when relevant).
  final String failureReason;

  /// The node's full response text, when this outcome carries one. The
  /// engine's terminal success sets it to the last executed node's response,
  /// so a caller that only sees the final outcome still gets the run's actual
  /// output instead of a bare "completed" note.
  final String text;

  const Outcome({
    required this.status,
    this.preferredLabel,
    this.suggestedNextIds = const [],
    this.contextUpdates = const {},
    this.notes = '',
    this.failureReason = '',
    this.text = '',
  });

  const Outcome.success({
    String? preferredLabel,
    List<String> suggestedNextIds = const [],
    Map<String, String> contextUpdates = const {},
    String notes = '',
    String text = '',
  }) : this(
          status: StageStatus.success,
          preferredLabel: preferredLabel,
          suggestedNextIds: suggestedNextIds,
          contextUpdates: contextUpdates,
          notes: notes,
          text: text,
        );

  const Outcome.fail(String this.failureReason, {String notes = ''})
      : status = StageStatus.fail,
        preferredLabel = null,
        suggestedNextIds = const [],
        contextUpdates = const {},
        this.notes = notes,
        text = '';

  const Outcome.retry(String reason)
      : status = StageStatus.retry,
        failureReason = reason,
        preferredLabel = null,
        suggestedNextIds = const [],
        contextUpdates = const {},
        notes = '',
        text = '';

  Outcome copyWith({StageStatus? status, String? preferredLabel}) => Outcome(
        status: status ?? this.status,
        preferredLabel: preferredLabel ?? this.preferredLabel,
        suggestedNextIds: suggestedNextIds,
        contextUpdates: contextUpdates,
        notes: notes,
        failureReason: failureReason,
        text: text,
      );

  Map<String, dynamic> toJson() => {
        'outcome': status.wire,
        if (preferredLabel != null && preferredLabel!.isNotEmpty)
          'preferred_label': preferredLabel,
        if (suggestedNextIds.isNotEmpty)
          'suggested_next_ids': suggestedNextIds,
        if (contextUpdates.isNotEmpty) 'context_updates': contextUpdates,
        if (notes.isNotEmpty) 'notes': notes,
        if (failureReason.isNotEmpty) 'failure_reason': failureReason,
        if (text.isNotEmpty) 'text': text,
      };
}
