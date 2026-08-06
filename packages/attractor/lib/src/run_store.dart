import 'context.dart';
import 'outcome.dart';

/// Persisted state for a single pipeline run. The host provides a concrete
/// implementation (a filesystem-backed store in tina); tests use an in-memory
/// one. The engine calls these after each node and at finalize, so a run
/// directory is always an up-to-date audit trail even before checkpoint
/// *resume* lands.
abstract class RunStore {
  /// Called once at run start. Write the manifest (run id, workflow name,
  /// goal, input, start time).
  Future<void> init({
    required String runId,
    required String workflowName,
    String? goal,
    String? input,
  });

  /// Called after a node completes. Write `<nodeId>/status.json`,
  /// `<nodeId>/prompt.md`, `<nodeId>/response.md`.
  Future<void> writeNode({
    required String nodeId,
    required Outcome outcome,
    required String prompt,
    required String response,
  });

  /// Called after each node. Write `checkpoint.json`
  /// (current/completed nodes, context snapshot).
  Future<void> writeCheckpoint({
    required String currentNode,
    required Iterable<String> completedNodes,
    required Context context,
  });

  /// Called when the run ends. Record final status in the manifest.
  Future<void> finalize({
    required StageStatus status,
    String? failureReason,
  });
}

/// An in-memory [RunStore] for tests. Captures every write for assertions.
class MemoryRunStore implements RunStore {
  String? runId;
  String? workflowName;
  final List<({String nodeId, Outcome outcome, String prompt, String response})>
      nodes = [];
  final List<({String currentNode, List<String> completed, Map<String, String> context})>
      checkpoints = [];
  StageStatus? finalStatus;

  @override
  Future<void> init({required String runId, required String workflowName, String? goal, String? input}) async {
    this.runId = runId;
    this.workflowName = workflowName;
  }

  @override
  Future<void> writeNode({required String nodeId, required Outcome outcome, required String prompt, required String response}) async {
    nodes.add((nodeId: nodeId, outcome: outcome, prompt: prompt, response: response));
  }

  @override
  Future<void> writeCheckpoint({required String currentNode, required Iterable<String> completedNodes, required Context context}) async {
    checkpoints.add((currentNode: currentNode, completed: completedNodes.toList(), context: context.snapshot()));
  }

  @override
  Future<void> finalize({required StageStatus status, String? failureReason}) async {
    finalStatus = status;
  }
}
