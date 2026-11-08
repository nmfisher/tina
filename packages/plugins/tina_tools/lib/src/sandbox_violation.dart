/// Thrown by enforcement boundaries when an operation is refused. Tools
/// catch this and surface it verbatim via `ToolResult.error`; callers
/// should not need to handle it.
///
/// This is the refusal that reaches the model: [message] is the reason,
/// safe to show the user — it never includes the resolved real path of a
/// sensitive tree, only the path the tool passed in.
///
/// Portable by design (no `dart:io`): the wasm engine's boundary throws
/// the same refusal the native one does, so a tool result carries the
/// same bytes on either platform.
class SandboxViolation implements Exception {
  final String message;
  const SandboxViolation(this.message);

  @override
  String toString() => message;
}
