/// Mounts the tool set and consults the session's mode plugin.
///
/// Permission state and approval routing live in `tina_mode`. The file system and the
/// process runner consult it **per call**. This plugin is where its value
/// is consulted: it builds the sandbox with the starting mode,
/// holds the handle to change it ([mode]), and tells the model
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
import 'package:tina_tools/tina_tools.dart';

final class ToolsPlugin extends AgentPlugin implements ModeControl {
  /// Whether the OS jail layer was requested. The layer itself decides per
  /// host whether a backend exists ([OsSandboxRunner.backend]); this flag
  /// records the host's decision to have the layer at all — `false` is a
  /// deliberate disable, `true` a degradation when no backend exists.
  final bool osSandbox;

  final ModePlugin modePolicy;

  ToolsPlugin({
    this.id = 'tina/tools',
    this.order = 10,
    required String workspaceRoot,
    required Directory tinaDir,
    PermissionMode mode = PermissionMode.ask,
    ModePlugin? modePolicy,
    this.osSandbox = true,
    UnavailableBehaviour osUnavailable = UnavailableBehaviour.allow,
    bool osIsolateNetwork = true,
  })  : modePolicy = modePolicy ?? ModePlugin(mode: mode),
        osPlan = SandboxPlan(
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
    final ProcessRunner osRunner = osSandbox
        ? OsSandboxRunner(
            inner: const IoProcessRunner(),
            plan: osPlan,
            unavailableBehaviour: osUnavailable,
            onWarn: (message) => stderr.writeln('tina: $message'),
          )
        : const IoProcessRunner();
    processRunner = SandboxedProcessRunner(
      inner: osRunner,
      mode: mode,
      writableDirectories: writable,
    );
    this.modePolicy.listen((value) {
      sandbox.mode = value;
      processRunner.mode = value;
    });
    sandbox.mode = this.modePolicy.mode;
    processRunner.mode = this.modePolicy.mode;
    toolList = [
      LsTool(workspaceRoot: workspaceRoot, sandbox: sandbox),
      ReadTool(fs: sandbox, workspaceRoot: workspaceRoot),
      WriteTool(fs: sandbox, workspaceRoot: workspaceRoot),
      EditTool(fs: sandbox, workspaceRoot: workspaceRoot),
      GlobTool(workspaceRoot: workspaceRoot, sandbox: sandbox),
      StatTool(workspaceRoot: workspaceRoot, sandbox: sandbox),
      BashTool(runner: processRunner, workingDirectory: workspaceRoot),
      ExecTool(runner: processRunner, workingDirectory: workspaceRoot),
    ];
    workingDirectory = workspaceRoot;
    attachModePolicy(this);
    prompt = HostPromptSection(workingDirectory, () => sandbox.mode);
  }

  /// The one configuration behind both the OS layout and the gate's
  /// writable directories. Exposed so a session report can name the plan;
  /// the plugin owns it, the host never touches it.
  final SandboxPlan osPlan;
  late final SandboxedProcessRunner processRunner;

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

  void mountOn(AgentLoop loop) {
    for (final t in toolList) {
      loop.registerContextExecutor(t.schema.name, (input, context) {
        if (t is ProcessToolBase) {
          return t.execute(input,
              control: ProcessControl(
                isCancelled: context.isCancelled,
                whenCancelled: context.whenCancelled,
                onOutput: context.report,
              ));
        }
        return t.execute(input);
      });
    }
  }

  late final HostPromptSection prompt;

  /// The mode as of now. Reading it is the plugin's business; a host that
  /// asks is a host that has started making permission decisions.
  PermissionMode get mode => modePolicy.mode;

  /// Switch the mode. The next tool call obeys it — the file system and
  /// the process runner read the value per call; nothing else changes.
  @override
  set mode(PermissionMode mode) {
    modePolicy.mode = mode;
  }

  @override
  void onPrompt(TurnContext c) =>
      c.promptSections.add(prompt.sectionFor(sandbox.mode));
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
      'Working directory: $workingDirectory. Mode: ${mode.label} — '
      '${switch (mode) {
        PermissionMode.ask => 'reads run; writes and commands require approval',
        PermissionMode.readOnly => 'reads run; writes and commands are refused',
        PermissionMode.allowEdits =>
          'project edits run; commands and outside writes require approval',
        PermissionMode.auto =>
          'reads run; a safety judge reviews writes and commands; uncertain decisions ask the user',
      }}.';
}
