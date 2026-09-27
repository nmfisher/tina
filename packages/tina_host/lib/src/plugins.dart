/// The plugin that mounts the tool set — and owns the session's
/// permission mode.
///
/// The mode mechanism lives in `tina_tools`: the file system and the
/// process runner consult it **per call**. This plugin is where its value
/// lives for a session: it builds the sandbox with the starting mode,
/// holds the handle to change it ([mode] / [setMode]), and tells the model
/// what the mode currently allows in its prompt section. The host itself
/// never asks what the mode is and never branches on it.
library;

import 'dart:io';

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tools/tina_tools.dart';

/// A plugin that has executors to put on the loop. The host honors this
/// at start — the loop is created there — without knowing anything else
/// about the plugin: not its tools, not its mode.
abstract interface class MountsTools {
  /// Register executors on [loop]. Called once, by [Host.start].
  void mountOn(AgentLoop loop);
}

/// The plugin that contributes the session's tools and owns the mode.
final class ToolsPlugin extends AgentPlugin implements MountsTools {
  ToolsPlugin({
    this.id = 'tools',
    this.order = 10,
    required String workspaceRoot,
    required Directory tinaDir,
    PermissionMode mode = PermissionMode.normal,
  })  : sandbox = SandboxedFileSystem(
          const IoFileSystem(),
          workspaceRoot: workspaceRoot,
          tinaDir: tinaDir,
          mode: mode,
        ) {
    toolList = [
      LsTool(workspaceRoot: workspaceRoot, sandbox: sandbox),
      ReadTool(fs: sandbox, workspaceRoot: workspaceRoot),
      WriteTool(fs: sandbox, workspaceRoot: workspaceRoot),
      EditTool(fs: sandbox, workspaceRoot: workspaceRoot),
      GlobTool(workspaceRoot: workspaceRoot, sandbox: sandbox),
      StatTool(workspaceRoot: workspaceRoot, sandbox: sandbox),
    ];
    workingDirectory = workspaceRoot;
    prompt = HostPromptSection(workingDirectory, () => sandbox.mode);
  }

  /// The session id for this plugin on the loop.
  @override
  final String id;

  @override
  final int order;

  /// The enforcement boundary every tool goes through, **consulted per
  /// call**. The plugin owns it; the host never touches it.
  final SandboxedFileSystem sandbox;

  /// The session's working directory.
  late final String workingDirectory;

  /// The session's tools. Their schemas are what the loop pins and
  /// advertises ([toolSchemas]); their executors are registered by
  /// [mountOn].
  late final List<Tool> toolList;

  @override
  List<ToolSchema> get tools => [
        for (final t in toolList) t.schema,
      ];

  /// Register every tool's executor on [loop].
  void mountOn(AgentLoop loop) {
    for (final t in toolList) {
      loop.registerExecutor(t.schema.name, t.execute);
    }
  }

  late final HostPromptSection prompt;

  /// The mode as of now. Reading it is the plugin's business; a host that
  /// asks is a host that has started making permission decisions.
  PermissionMode get mode => sandbox.mode;

  /// Switch the mode. The next tool call obeys it — the file system and
  /// the process runner read the value per call; nothing else changes.
  void setMode(PermissionMode mode) => sandbox.mode = mode;

  @override
  void onPrompt(TurnContext c) => c.promptSections.add(prompt.sectionFor(sandbox.mode));
}

/// The persona: who the agent is. The core owns no prompt text, so the
/// words live here, first section of every request.
final class PersonaPlugin extends AgentPlugin {
  const PersonaPlugin({this.id = 'persona', this.order = 5});

  /// The session id for this plugin on the loop.
  @override
  final String id;

  /// Before the tools section, so the persona leads the prompt.
  @override
  final int order;

  @override
  void onPrompt(TurnContext c) =>
      c.promptSections.add('You are tina, a terminal coding agent.');
}

/// The prompt section the tools plugin contributes: where the session
/// works and what the current mode allows. The loop owns the join; this
/// is one section, never a prompt.
final class HostPromptSection {
  HostPromptSection(this.workingDirectory, this.modeOf);

  final String workingDirectory;
  final PermissionMode Function() modeOf;

  /// The section for a given mode — the words the model reads.
  String sectionFor(PermissionMode mode) =>
      'Working directory: $workingDirectory. '
      'Mode: ${mode == PermissionMode.readOnly ? 'read-only' : 'normal'} — '
      '${mode == PermissionMode.readOnly
          ? 'writes are refused; reads run'
          : 'reads run; writes inside the working directory run; writes '
              'outside it are refused unless approved'}.';
}
