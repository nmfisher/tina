/// A single tool invocation's UI state in the tool strip.
///
/// One [ToolChip] exists per in-flight or recently-finished tool call. The
/// strip renders them left-to-right; the output panel shows the
/// [outputBuffer] of the focused chip. `state` and `outputBuffer` are mutable
/// because they change over the tool's lifecycle — the class is intentionally
/// not `@immutable`.
enum ToolChipState { running, success, error }

class ToolChip {
  final String toolName;
  final String toolId;
  ToolChipState state;
  final StringBuffer outputBuffer;

  ToolChip({required this.toolName, required this.toolId})
      : state = ToolChipState.running,
        outputBuffer = StringBuffer();
}
