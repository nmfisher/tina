import 'package:attractor/attractor.dart';

import 'classify_handler.dart';
import 'classify_program.dart';

/// Runs a classifier [program] through the stock [PipelineEngine] with exactly
/// one classification handler: `type="classify"` nodes resolve to
/// [ClassifyHandler] bound to [runStage]; start/exit/conditional routing nodes
/// use attractor's stock handlers. The registry's default handler is the
/// engine's fail-closed unknown handler — a stray `type` in a program can
/// never fall through to the chat/codergen backend.
///
/// The [runStore] defaults to an in-memory audit trail: classification
/// checkpoints live in the classification store (byte-identical plan ids and
/// evidence keys), so the engine's per-node audit need not be persisted for
/// `/index` runs. [cancelSignal] reaches the stage runner through the handler
/// and maps any settled stage to `fail("cancelled")` (see [ClassifyHandler]).
///
/// Throws [StateError] when the program is invalid — callers surface
/// diagnostics from `loadIndexProgram`; a broken program is never silently
/// replaced by the built-in.
Future<Outcome> runClassifyProgram({
  required ClassifyProgram program,
  required ClassifyStageRunner runStage,
  Future<void>? cancelSignal,
  PipelineEventListener? onEvent,
  RunStore? runStore,
  String? runId,
}) async {
  if (!program.valid) {
    throw StateError(
      'invalid classify program "${program.name}" (${program.origin}):\n'
      '${program.errorsText}',
    );
  }
  final registry = NodeHandlerRegistry()
    ..register('start', StartHandler())
    ..register('exit', ExitHandler())
    ..register('conditional', ConditionalHandler())
    ..register('classify', ClassifyHandler(runStage));
  final engine = PipelineEngine(
    graph: program.graph,
    registry: registry,
    runStore: runStore ?? MemoryRunStore(),
    runId: runId ?? 'classify-${DateTime.now().microsecondsSinceEpoch}',
    workflowName: program.name,
    onEvent: onEvent,
    cancelSignal: cancelSignal,
  );
  return engine.run();
}
