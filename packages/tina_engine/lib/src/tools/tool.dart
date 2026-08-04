class ToolSchema {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  const ToolSchema({
    required this.name,
    required this.description,
    required this.inputSchema,
  });
}

class ToolResult {
  final String content;
  final bool isError;
  const ToolResult(this.content, {this.isError = false});

  factory ToolResult.error(String message) =>
      ToolResult(message, isError: true);
}

/// Callback for tools that emit incremental output. [stderr] is true when the
/// chunk came from the process's stderr (or analogous "error" channel). Most
/// tools don't produce streaming output; only BashTool calls this today.
typedef ToolOutputCallback = void Function(String chunk, {bool stderr});

abstract class Tool {
  ToolSchema get schema;

  /// Run the tool. [cancelSignal] is completed when the user has asked to
  /// abort the current turn (ESC). Long-running tools should listen and stop
  /// promptly — `bash` kills the spawned process; fast tools can ignore it.
  ///
  /// [onOutput] receives incremental output for tools that produce it, so the
  /// REPL can render a `cargo build` log as it streams rather than blocking
  /// silently until the process exits.
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  });
}

/// Registry of tools keyed by schema name. Construction is **last-wins**: if
/// two tools share a name, the later entry in [tools] shadows the earlier
/// (the map literal assigns each name in iteration order). This is deliberate
/// — the composition helpers [withDelegateTool] and [withBackgroundTools], plus
/// [SubAgentScheduler]'s per-stage registry, all append onto a base registry
/// (`[...base.all, ...]`) to extend or override it; a throw-on-duplicate policy
/// would break that pattern.
class ToolRegistry {
  final Map<String, Tool> _tools;
  ToolRegistry(List<Tool> tools)
      : _tools = {for (final t in tools) t.schema.name: t};

  Tool? operator [](String name) => _tools[name];
  Iterable<Tool> get all => _tools.values;
  List<ToolSchema> get schemas => _tools.values.map((t) => t.schema).toList();
}

/// The lifecycle of a single tool call, as a payload. Carried by the agent's
/// [AgentSink] tool methods (Stage 4), the tool strip, and the broadcast bus.
/// `conversationId` is optional: set when known so the UI can filter per
/// conversation; left null when the emitter has no conversation context.
sealed class ToolEvent {
  final String toolName;
  final String toolId;
  final String? conversationId;

  const ToolEvent(this.toolName, this.toolId, {this.conversationId});
}

/// A tool is about to execute (after permission approval).
class ToolStartEvent extends ToolEvent {
  final Map<String, dynamic> input;

  const ToolStartEvent(
    super.toolName,
    super.toolId,
    this.input, {
    super.conversationId,
  });
}

/// Incremental output from a running tool (e.g. bash stdout/stderr).
class ToolOutputEvent extends ToolEvent {
  final String chunk;
  final bool stderr;

  const ToolOutputEvent(
    super.toolName,
    super.toolId,
    this.chunk, {
    this.stderr = false,
    super.conversationId,
  });
}

/// A tool finished — success or failure.
class ToolCompleteEvent extends ToolEvent {
  final bool isError;
  final String result;

  const ToolCompleteEvent(
    super.toolName,
    super.toolId, {
    required this.isError,
    required this.result,
    super.conversationId,
  });
}
