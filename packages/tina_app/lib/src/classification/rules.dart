import 'package:classifier/classification.dart';
import 'package:classifier/judgments.dart' show JudgmentCancellation;
import 'package:tina_engine/tina_engine.dart';

/// Scheduling points, not classifier input formats. Adapters supply the typed
/// context C of a Rule<C, I, O> at the corresponding boundary.
enum RuleTrigger { input, tool, result }

enum RuleAction { proceed, block, review }

/// Policy is separate from inference. A classifier's unknown/partial output
/// must be handled explicitly by Rule.decide; it does not imply permission.
final class RuleDecision {
  final RuleAction action;
  final String reason;
  const RuleDecision(this.action, this.reason);
}

/// Portable settings for a registered rule implementation. No closures, raw
/// instruction bodies, or cached classifications belong in this record.
/// A loader must resolve the exact implementation ID/revision and verify the
/// instruction reference before enabling it. Missing/stale bindings stay off.
final class RuleConfig {
  final String id;
  final String implementation;
  final int revision;
  final InstructionRef instruction;
  final RuleTrigger trigger;
  final Map<String, Object?> options;

  RuleConfig({
    required this.id,
    required this.implementation,
    required this.revision,
    required this.instruction,
    required this.trigger,
    Map<String, Object?> options = const {},
  }) : options = freezeJson(options) as Map<String, Object?> {
    if (id.isEmpty ||
        implementation.isEmpty ||
        revision < 1 ||
        instruction.id.isEmpty ||
        instruction.revision.isEmpty) {
      throw ArgumentError('Invalid rule configuration');
    }
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'implementation': implementation,
    'revision': revision,
    'instruction': {'id': instruction.id, 'revision': instruction.revision},
    'trigger': trigger.name,
    'options': options,
  };

  factory RuleConfig.fromJson(Map<String, Object?> json) {
    final source = json['instruction'] as Map;
    return RuleConfig(
      id: json['id'] as String,
      implementation: json['implementation'] as String,
      revision: json['revision'] as int,
      instruction: InstructionRef(
        source['id'] as String,
        source['revision'] as String,
      ),
      trigger: RuleTrigger.values.byName(json['trigger'] as String),
      options: (json['options'] as Map).cast<String, Object?>(),
    );
  }
}

/// A plugin contribution using the existing classification machinery.
/// C is boundary context, I is encoded evidence, O is the classification.
/// The task owns source/plan selection, including chunking and budgets through
/// the existing orchestrator. It must identify all relevant context in its
/// source revision so classifications are not reused across different inputs.
///
/// No runner is installed yet. A future adapter validates config identity and
/// instruction revision, runs task through ClassificationOrchestrator, then
/// applies decide. InputProcessor, ToolCheck and ToolResultHook are the existing
/// boundaries; a Rule contribution alone does not activate enforcement.
abstract interface class Rule<C, I, O> implements Component {
  int get revision;
  RuleTrigger get trigger;
  ClassificationTask<I, O> task(RuleConfig config, C context);
  RuleDecision decide(RuleConfig config, ClassificationResult<O> result);
}

/// Analysis produces candidates, never permission changes. A plugin can use
/// InstructionObserver to schedule this work as its own cancellable Invocation.
/// No analyzer or automatic scheduling is supplied by the framework.
abstract interface class RuleAnalyzer implements Component {
  Future<List<RuleProposal>> analyze(
    InstructionLoad instructions,
    JudgmentCancellation cancellation,
  );
}

final class RuleProposal {
  final RuleConfig rule;
  final String explanation;
  const RuleProposal(this.rule, this.explanation);
}

enum RuleState { proposed, enabled, dismissed, stale }

/// Review state is scoped to the config's instruction and implementation
/// revisions. Editing either requires fresh review, not silent reactivation.
final class RuleRecord {
  final RuleProposal proposal;
  final RuleState state;
  const RuleRecord(this.proposal, this.state);

  Map<String, Object?> toJson() => {
    'version': 1,
    'rule': proposal.rule.toJson(),
    'explanation': proposal.explanation,
    'state': state.name,
  };

  factory RuleRecord.fromJson(Map<String, Object?> json) {
    if (json['version'] != 1)
      throw const FormatException('Unknown rule record version');
    return RuleRecord(
      RuleProposal(
        RuleConfig.fromJson((json['rule'] as Map).cast<String, Object?>()),
        json['explanation'] as String,
      ),
      RuleState.values.byName(json['state'] as String),
    );
  }
}

/// Storage is separate from the classification cache. Implementations are
/// project-scoped and write each record atomically. No database is opened or
/// new on-disk store created merely by importing/registering these contracts.
abstract interface class RuleStore {
  Future<List<RuleRecord>> read();
  Future<void> write(RuleRecord record);
  Future<void> remove(String id);
}
