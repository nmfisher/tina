import '../node_handler.dart';

/// The pipeline entry point — a no-op that returns success immediately.
class StartHandler implements NodeHandler {
  @override
  Future<Outcome> execute({
    required PipelineNode node,
    required Graph graph,
    required Context context,
    required RunStore runStore,
    Future<void>? cancelSignal,
  }) async =>
      const Outcome.success(notes: 'pipeline start');
}
