/// The plugin that mounts the tool set — and owns the session's
/// permission mode.
///
/// The mode mechanism lives in `tina_tools`: the file system and the
/// process runner consult it **per call**. This plugin is where its value
/// lives for a session: it builds the sandbox with the starting mode,
/// holds the handle to change it ([mode] / [setMode]), and tells the model
/// what the mode currently allows in its prompt section. The host itself
/// never asks what the mode is and never branches on it.
///
/// Process execution is layered, innermost last:
/// `IoProcessRunner` (the real spawn) → `OsSandboxRunner` (the jail) →
/// `SandboxedProcessRunner` (the gate, outermost). The gate stays the
/// outermost layer so refusals never reach the OS; the jail catches what
/// argument inspection cannot see. The plan is built **once**
/// ([ToolsPlugin.osPlan]) and drives both the jail's layout and the gate's
/// writable directories, so approval and confinement cannot disagree.
library;

import 'dart:io';

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_services/tina_services.dart';
import 'package:tina_tools/tina_tools.dart';

/// A plugin that has executors to put on the loop. The host honors this
/// at start — the loop is created there — without knowing anything else
/// about the plugin: not its tools, not its mode.
abstract interface class MountsTools {
  /// Register executors on [loop]. Called once, by [Host.start].
  void mountOn(AgentLoop loop);
}

/// The plugin that contributes the session's tools and owns the mode.
/// Under a shared locator it *registers itself* as the session's
/// [ModeControl] — the brief's wording is literal: the object published
/// under the mode-service type is the boundary's owner, not a copy.
final class ToolsPlugin extends AgentPlugin implements MountsTools, ModeControl {
  /// Whether the OS jail layer was requested. The layer itself decides per
  /// host whether a backend exists ([OsSandboxRunner.backend]); this flag
  /// records the host's decision to have the layer at all — `false` is a
  /// deliberate disable, `true` a degradation when no backend exists.
  final bool osSandbox;

  ToolsPlugin({
    this.id = 'tools',
    this.order = 10,
    required String workspaceRoot,
    required Directory tinaDir,
    PermissionMode mode = PermissionMode.normal,
    this.osSandbox = true,
    UnavailableBehaviour osUnavailable = UnavailableBehaviour.allow,
    bool osIsolateNetwork = true,
    Services? services,
  })  : osPlan = SandboxPlan(
          workspaceRoot: workspaceRoot,
          tinaDir: tinaDir.path,
          isolateNetwork: osIsolateNetwork,
        ),
        sandbox = SandboxedFileSystem(
          const IoFileSystem(),
          workspaceRoot: workspaceRoot,
          tinaDir: tinaDir,
          mode: mode,
        ) {
    final writable = WritableDirectories(osPlan.writableLayout());
    final osRunner = OsSandboxRunner(
      inner: const IoProcessRunner(),
      plan: osPlan,
      unavailableBehaviour: osUnavailable,
      onWarn: (message) => stderr.writeln('tina: $message'),
    );
    final gated = SandboxedProcessRunner(
      inner: osRunner,
      mode: mode,
      writableDirectories: writable,
    );
    toolList = [
      LsTool(workspaceRoot: workspaceRoot, sandbox: sandbox),
      ReadTool(fs: sandbox, workspaceRoot: workspaceRoot),
      WriteTool(fs: sandbox, workspaceRoot: workspaceRoot),
      EditTool(fs: sandbox, workspaceRoot: workspaceRoot),
      GlobTool(workspaceRoot: workspaceRoot, sandbox: sandbox),
      StatTool(workspaceRoot: workspaceRoot, sandbox: sandbox),
      BashTool(runner: gated),
      ExecTool(runner: gated),
    ];
    workingDirectory = workspaceRoot;
    prompt = HostPromptSection(workingDirectory, () => sandbox.mode);
    _services = services;
  }

  /// The one configuration behind both the OS layout and the gate's
  /// writable directories. Exposed so a session report can name the plan;
  /// the plugin owns it, the host never touches it.
  final SandboxPlan osPlan;

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

  /// The locator this session shares, or null when none was handed in.
  Services? _services;

  /// The session's tools. Their schemas are what the loop pins and
  /// advertises ([toolSchemas]); their executors are registered by
  /// [mountOn].
  late final List<Tool> toolList;

  @override
  List<ToolSchema> get tools => [
        for (final t in toolList) t.schema,
      ];

  /// Register every tool's executor on [loop]. If the session shares a
  /// locator, the plugin publishes **itself** as the [ModeControl] — the
  /// same moment the tools become reachable, so code resolving at use
  /// (the locator's one rule) always finds it.
  void mountOn(AgentLoop loop) {
    for (final t in toolList) {
      loop.registerExecutor(t.schema.name, t.execute);
    }
    _services?.put<ModeControl>(this);
  }

  late final HostPromptSection prompt;

  /// The mode as of now. Reading it is the plugin's business; a host that
  /// asks is a host that has started making permission decisions.
  PermissionMode get mode => sandbox.mode;

  /// Switch the mode. The next tool call obeys it — the file system and
  /// the process runner read the value per call; nothing else changes.
  @override
  set mode(PermissionMode mode) => sandbox.mode = mode;

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
