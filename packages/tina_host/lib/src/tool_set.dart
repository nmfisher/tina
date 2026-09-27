/// The six file tools over one sandboxed filesystem, registered on the loop.
///
/// The host builds this once per session: one `IoFileSystem` inside one
/// `SandboxedFileSystem` (the enforcement boundary — mode consulted per
/// call), and the six tools the brief names (ls, read, write, edit, glob,
/// stat) wired so their schemas reach the provider and their executors
/// run when the model calls them.
library;

import 'dart:io';

import 'package:tina_engine_2/tina_engine_2.dart' show AgentLoop;
import 'package:tina_tools/tina_tools.dart';

/// The six tools of a session, sharing one sandbox.
final class ToolSet {
  /// The boundary every tool writes and reads through. Mode is live:
  /// flip [SandboxedFileSystem.mode] and the next call obeys it.
  final SandboxedFileSystem sandbox;

  /// The tools, in the order their schemas are advertised.
  final List<Tool> tools;

  ToolSet._(this.sandbox, this.tools);

  /// Build for [workspaceRoot]: a real `IoFileSystem` under a
  /// [SandboxedFileSystem] whose project root is the workspace, the Tina
  /// data tree is denied, and [mode] is the starting mode. The asker stays
  /// unwired (asks deny, fail closed) — wiring a UI asker is the TUI's
  /// slice, not the host's.
  factory ToolSet.forWorkspace({
    required String workspaceRoot,
    required Directory tinaDir,
    PermissionMode mode = PermissionMode.normal,
  }) {
    final sandbox = SandboxedFileSystem(
      const IoFileSystem(),
      workspaceRoot: workspaceRoot,
      tinaDir: tinaDir,
      mode: mode,
    );
    final tools = [
      LsTool(workspaceRoot: workspaceRoot, sandbox: sandbox),
      ReadTool(fs: sandbox, workspaceRoot: workspaceRoot),
      WriteTool(fs: sandbox, workspaceRoot: workspaceRoot),
      EditTool(fs: sandbox, workspaceRoot: workspaceRoot),
      GlobTool(workspaceRoot: workspaceRoot, sandbox: sandbox),
      StatTool(workspaceRoot: workspaceRoot, sandbox: sandbox),
    ];
    return ToolSet._(sandbox, tools);
  }

  /// Advertise every tool's schema and register every tool's executor on
  /// [loop]. One tool, one entry in each.
  void mountOn(AgentLoop loop) {
    for (final t in tools) {
      loop.registerExecutor(t.schema.name, t.execute);
    }
  }
}
