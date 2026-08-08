import 'context.dart';
import 'graph.dart';
import 'outcome.dart';
import 'run_store.dart';

// Re-export so a handler file needs only `import '../node_handler.dart'`.
export 'context.dart';
export 'graph.dart';
export 'outcome.dart';
export 'run_store.dart';

/// A progress event the engine emits during a run, for the UI to render.
class PipelineEvent {
  /// `started`, `node_started`, `node_completed`, `node_failed`, `node_retrying`,
  /// `gate`, `completed`, `failed`.
  final String kind;

  final String? nodeId;
  final Outcome? outcome;
  final String? message;

  const PipelineEvent(this.kind, {this.nodeId, this.outcome, this.message});

  @override
  String toString() =>
      'PipelineEvent($kind, node=$nodeId${message == null ? '' : ', "$message"'})';
}

typedef PipelineEventListener = void Function(PipelineEvent event);

/// One node's behavior. The engine dispatches to the handler a node resolves
/// to (by explicit `type`, else shape, else the default `codergen` handler).
/// Handlers are stateless beyond their constructor-injected dependencies (a
/// backend, an interviewer); the engine supplies the per-run state in
/// [execute]. [onEvent] is the run's progress listener, threaded from the
/// engine so a handler can emit `node_started`/`node_completed`/… for work it
/// executes itself (e.g. parallel branches) that bypasses the engine's own
/// emit sites.
abstract class NodeHandler {
  Future<Outcome> execute({
    required PipelineNode node,
    required Graph graph,
    required Context context,
    required RunStore runStore,
    Future<void>? cancelSignal,
    PipelineEventListener? onEvent,
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
    PipelineEventListener? onEvent,
  }) async =>
      Outcome.fail('no handler registered for type "${node.handlerType}"');
}
