import '../node_handler.dart';

/// A routing-only node (`diamond`). The handler itself is a no-op returning
/// success; the actual routing happens in the engine's edge-selection, which
/// evaluates the `condition`s on the node's outgoing edges.
class ConditionalHandler implements NodeHandler {
  @override
  Future<Outcome> execute({
    required PipelineNode node,
    required Graph graph,
    required Context context,
    required RunStore runStore,
    Future<void>? cancelSignal,
    PipelineEventListener? onEvent,
  }) async =>
      Outcome.success(notes: 'conditional node: ${node.id}');
}
