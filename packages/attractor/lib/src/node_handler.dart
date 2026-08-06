import 'context.dart';
import 'graph.dart';
import 'outcome.dart';
import 'run_store.dart';

// Re-export so a handler file needs only `import '../node_handler.dart'`.
export 'context.dart';
export 'graph.dart';
export 'outcome.dart';
export 'run_store.dart';

/// One node's behavior. The engine dispatches to the handler a node resolves
/// to (by explicit `type`, else shape, else the default `codergen` handler).
/// Handlers are stateless beyond their constructor-injected dependencies (a
/// backend, an interviewer); the engine supplies the per-run state in
/// [execute].
abstract class NodeHandler {
  Future<Outcome> execute({
    required PipelineNode node,
    required Graph graph,
    required Context context,
    required RunStore runStore,
    Future<void>? cancelSignal,
  });
}

/// Maps a handler-type string to its [NodeHandler], with a fallback default
/// (the codergen/LLM handler). Resolution mirrors the spec: explicit `type` →
/// shape-to-type → default.
class NodeHandlerRegistry {
  final Map<String, NodeHandler> _byType = {};

  /// The handler used when a node's resolved type is unrecognized. Defaults to
  /// a handler that returns a fail outcome ("unknown handler"); the engine
  /// installer sets this to the codergen handler.
  NodeHandler defaultHandler = _UnknownHandler();

  void register(String type, NodeHandler handler) => _byType[type] = handler;

  NodeHandler resolve(PipelineNode node) {
    final type = node.handlerType;
    return _byType[type] ?? defaultHandler;
  }
}

class _UnknownHandler implements NodeHandler {
  @override
  Future<Outcome> execute({
    required PipelineNode node,
    required Graph graph,
    required Context context,
    required RunStore runStore,
    Future<void>? cancelSignal,
  }) async =>
      Outcome.fail('no handler registered for type "${node.handlerType}"');
}
