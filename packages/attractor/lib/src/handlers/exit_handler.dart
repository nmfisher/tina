import '../node_handler.dart';

/// The pipeline exit point — a no-op that returns success immediately. Goal
/// gates are enforced by the engine (it checks them when it reaches a
/// terminal node), not by this handler.
class ExitHandler implements NodeHandler {
  @override
  Future<Outcome> execute({
    required PipelineNode node,
    required Graph graph,
    required Context context,
    required RunStore runStore,
    Future<void>? cancelSignal,
    PipelineEventListener? onEvent,
  }) async =>
      const Outcome.success(notes: 'pipeline exit');
}
