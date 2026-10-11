import 'package:tina_core/tina_core.dart';

import 'file_system.dart';
import 'io_file_system.dart';
import 'permissions.dart';
import 'sandboxed_file_system.dart';
import 'tool_input.dart';

export 'permissions.dart' show FileOp;

/// The single file-path front door for the file-touching tools.
///
/// One object owns the preamble every tool used to repeat inline: resolve the
/// model-supplied path against the workspace root ([resolveToolPath]), then
/// push the operation through the sandbox boundary ([SandboxedFileSystem.guard])
/// *before* any existence probe. Tools hand in the raw input and stop
/// pre-checking; the [ToolResult.error] the guard's [SandboxViolation] maps to
/// is produced here, exactly as the inline copies did.
///
/// Two deliberate consequences:
///
/// - The boundary is consulted **once** per tool operation. The tools no
///   longer do their own `fs is SandboxedFileSystem` dance in addition to the
///   guards [SandboxedFileSystem] runs inside its [FileSystem] methods — the
///   seam's internal guards remain (its direct users and the atomic-write
///   temp bookkeeping depend on them), but the tool-side preamble stops
///   stacking a duplicate check on top of them.
/// - The wrapper is also where a virtual mount (e.g. `context://live`) will
///   route later. Landed with none registered, so today it is pure
///   deduplication with zero behavior change.
class ToolFileSystem {
  /// The underlying filesystem the tools read and write through.
  final FileSystem fs;

  /// The workspace root relative paths resolve against. Null retains
  /// standalone cwd-relative behavior.
  final String? workspaceRoot;

  /// The sandbox boundary to consult for every operation. Null — the
  /// common test configuration ([MemoryFileSystem], bare [IoFileSystem]) —
  /// skips the guard entirely, as the tools' own `is` checks did.
  final SandboxedFileSystem? sandbox;

  const ToolFileSystem(this.fs, {this.workspaceRoot, this.sandbox});

  /// Wraps an existing tool filesystem: guards when [fs] *is* a
  /// [SandboxedFileSystem], matching the tools' old inline `is` check.
  factory ToolFileSystem.of(FileSystem fs, {String? workspaceRoot}) =>
      ToolFileSystem(fs,
          workspaceRoot: workspaceRoot,
          sandbox: fs is SandboxedFileSystem ? fs : null);

  /// Resolve a raw model-supplied path the way every tool did.
  String resolve(String rawPath) => resolveToolPath(rawPath, workspaceRoot);

  /// Guard [op] at [path], which must already be resolved. Returns the
  /// tool-facing error when the boundary refuses, and null when the operation
  /// may proceed. Never throws.
  Future<ToolResult?> guard(FileOp op, String path) async {
    final boundary = sandbox;
    if (boundary == null) return null;
    try {
      await boundary.guard(op, path);
    } on SandboxViolation catch (e) {
      return ToolResult.error(e.message);
    }
    return null;
  }

  /// Run [body] for [op] at resolved [path] under the boundary's once-per-
  /// operation decision: the ask reaches the approver exactly once, a refusal
  /// becomes the tool-facing [ToolResult.error] (never an exception), and the
  /// seam's internal re-guards inside [body] are absorbed by the enclosing
  /// authorization. With no boundary configured, [body] runs unchanged.
  ///
  /// The one entry point for tools whose whole operation is a single
  /// resolve-guard-execute sweep (read / write / edit); structural-only
  /// tools (stat / glob / ls) keep using [guard] around their own probes.
  Future<ToolResult> run(
      FileOp op, String path, Future<ToolResult> Function() body) async {
    final boundary = sandbox;
    if (boundary == null) return body();
    try {
      return await boundary.authorizeOperation(op, path, body);
    } on SandboxViolation catch (e) {
      return ToolResult.error(e.message);
    }
  }
}
