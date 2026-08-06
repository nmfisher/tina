/// Attractor: a DOT-based pipeline runner.
///
/// A workflow is a Graphviz DOT `digraph` where nodes are tasks (an LLM call,
/// a human gate, a conditional routing point) and edges carry `condition` /
/// `label` / `weight` for routing. The engine traverses the graph from a start
/// node, executing each node's handler and selecting the next edge. Back-edges
/// are just edges, so feedback loops (e.g. a reviewer sending a plan back to
/// the planner) fall out for free.
///
/// This package is the orchestration layer only — it has no LLM or UI
/// dependency. Two seams are left open for the host application:
/// - [CodergenBackend]: turn a `box`/LLM node into a result, and
/// - [Interviewer]: present a `hexagon`/human-gate node to a human.
library attractor;

export 'src/graph.dart';
export 'src/context.dart';
export 'src/outcome.dart';
export 'src/codergen_backend.dart';
export 'src/interviewer.dart';
export 'src/run_store.dart';
export 'src/node_handler.dart';
export 'src/handlers/handlers.dart';
export 'src/condition.dart';
export 'src/dot_parser.dart';
export 'src/engine.dart';
export 'src/validator.dart';
