import 'permissions.dart' show FileOp;

/// The per-operation authorization surface the tools' path front door
/// ([ToolFileSystem]) consults when the filesystem it was handed carries
/// an enforcement boundary.
///
/// [SandboxedFileSystem] (native, `dart:io`-backed canonicalization)
/// implements this, and so does the portable asking boundary a wasm
/// composition root mounts — the tools and [ToolFileSystem] treat both
/// identically: check once per operation, ask exactly once, refuse as a
/// [SandboxViolation] the tool maps to `ToolResult.error`.
abstract interface class ToolBoundary {
  /// Check [op] at resolved [path] once; refuse by throwing.
  Future<void> guard(FileOp op, String path);

  /// Run [body] with [op] at resolved [path] pre-authorized: interior
  /// re-guards of the same operation and target (including the staging
  /// paths an atomic write uses) are absorbed by the enclosing decision.
  Future<T> authorizeOperation<T>(
      FileOp op, String path, Future<T> Function() body);
}
