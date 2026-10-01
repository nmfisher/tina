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
import 'dart:async';

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tools/tina_tools.dart';

abstract interface class ToolSessionSource implements ModePolicySource {
  PermissionMode get mode;
  String get workingDirectory;
  bool get osSandbox;
}

final class ToolsPlugin extends AgentPlugin
    implements ModeControl, ToolSessionSource {
  /// Whether OS confinement was requested. The wrapper decides whether a
  /// backend exists ([OsSandboxRunner.backend]); false deliberately bypasses
  /// the jail while preserving environment filtering and permission checks.
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
    final osRunner = OsSandboxRunner(
      inner: const IoProcessRunner(),
      plan: osPlan,
      enabled: osSandbox,
      unavailableBehaviour: osUnavailable,
      onWarn: (message) => stderr.writeln('tina: $message'),
    );
    processRunner = SandboxedProcessRunner(
      inner: osRunner,
      mode: mode,
      writableDirectories: writable,
      executableSearchPath: osPlan.childEnvironment['PATH'],
    );
    processJobs = ProcessJobs(processRunner);
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
      BashTool(runner: processJobs, workingDirectory: workspaceRoot),
      ExecTool(runner: processJobs, workingDirectory: workspaceRoot),
      ProcessJobTool(processJobs),
    ];
    workingDirectory = workspaceRoot;
    attachModePolicy(this);
    prompt = HostPromptSection(workingDirectory, () => sandbox.mode,
        sandboxDescription: osRunner.describeEnvironment);
  }

  /// The one configuration behind both the OS layout and the gate's
  /// writable directories. Exposed so a session report can name the plan;
  /// the plugin owns it, the host never touches it.
  final SandboxPlan osPlan;
  late final SandboxedProcessRunner processRunner;
  late final ProcessJobs processJobs;

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
  ToolUse? _activeCall;

  ToolDescription describeFileRequest(String operation, String path) {
    final call = _activeCall;
    final describe = call == null
        ? null
        : toolList
            .where((tool) => tool.schema.name == call.name)
            .firstOrNull
            ?.schema
            .describe;
    final description = call == null ? null : describe?.call(call.input);
    return ToolDescription(
        title: description?.title ??
            (operation == 'read'
                ? 'Read file'
                : operation == 'write'
                    ? 'Write file'
                    : operation),
        target: path,
        fields: description?.fields ?? const {});
  }

  @override
  List<ToolSchema> get tools => [
        for (final t in toolList) t.schema,
      ];

  void mountOn(AgentLoop loop) {
    modePolicy.mountPolicy(loop, ownerId: id);
    for (final t in toolList) {
      loop.registerContextExecutor(t.schema.name, (input, context) {
        if (t is ProcessJobTool) {
          return t.execute(input,
              control: ProcessControl(
                  isCancelled: context.isCancelled,
                  whenCancelled: context.whenCancelled,
                  whenInputPending: context.whenInputPending,
                  onOutput: context.report));
        }
        if (t is ProcessToolBase) {
          return t.execute(input,
              control: ProcessControl(
                isCancelled: context.isCancelled,
                whenCancelled: context.whenCancelled,
                whenInputPending: context.whenInputPending,
                onOutput: context.report,
              ));
        }
        return t.execute(input);
      });
    }
  }

  @override
  void onInput(TurnContext c) => modePolicy.onInput(c);
  @override
  void beforeToolCall(TurnContext c) {
    _activeCall = c.call;
    modePolicy.beforeToolCall(c);
  }

  @override
  void afterToolResult(TurnContext c) {
    _activeCall = null;
    modePolicy.afterToolResult(c);
  }

  @override
  void onTurnEnd(TurnContext c) {
    _activeCall = null;
    modePolicy.onTurnEnd(c);
  }

  @override
  void closeSession() {
    unawaited(processJobs.close());
    modePolicy.closeSession();
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
  HostPromptSection(this.workingDirectory, this.modeOf,
      {this.sandboxDescription});

  final String workingDirectory;
  final PermissionMode Function() modeOf;
  final String Function()? sandboxDescription;

  /// The section for a given mode — the words the model reads.
  String sectionFor(PermissionMode mode) =>
      'Working directory: $workingDirectory. Mode: ${mode.label} — '
      '${switch (mode) {
        PermissionMode.ask => 'reads run; writes and commands require approval',
        PermissionMode.readOnly =>
          'reads and verified direct system ls/grep commands run; '
              'writes and other commands require explicit user approval',
        PermissionMode.allowEdits =>
          'project edits run; commands and outside writes require approval',
        PermissionMode.auto =>
          'reads run; a safety judge reviews writes and commands; uncertain decisions ask the user',
      }}.\n\n'
      '${sandboxDescription?.call() ?? ''}\n\n'
      'Ordinary command approval does not change the OS confinement described '
      'above; it does not expose hidden paths or remove filesystem limits. '
      'If this exact command needs unavailable access, set outside_sandbox: '
      'true and sandbox_reason on exec or bash. This requests human approval '
      'even in auto mode and grants host filesystem and network access only '
      'to this invocation and its subprocess tree. An exact human session '
      'grant may cover a later identical explicit request. The environment '
      'remains filtered. Do not retry unchanged, switch shells, copy '
      'executables or ask the user to run commands manually as a sandbox '
      'workaround. Respect denied or cancelled approvals.\n\n'
      'Prefer dedicated file tools for listing, reading, searching paths and '
      'editing. When a command is needed, use exec to run programs such as '
      'ls, grep, sed and find directly with literal arguments. Avoid bash '
      'and sh wrappers whenever possible; do not use exec to invoke sh -c '
      'or bash -c as a workaround. Use bash only when shell features such as '
      'pipes, redirects or expansions are actually required. Exec passes options '
      'and subcommands unchanged; it does not perform shell quoting or expansion. '
      'For commands requiring network access, set network: true and network_reason '
      'on exec or bash. Execution and network are reviewed together under the '
      'current permission mode. Network permission applies to the entire '
      'subprocess tree; when OS confinement is enabled the filesystem sandbox '
      'stays active unless outside_sandbox was also explicitly approved. Retrying '
      'reruns the entire command; do not claim the user must run it manually.\n\n'
      'For long builds, servers and polling loops, set background: true on '
      'exec or bash, and set an appropriate timeout in seconds (default 600). '
      'This returns a job ID after approval and startup so you can handle other '
      'work. Use process to check status, wait with wait_ms, or cancel. Never '
      'restart a command that already has a live job. Background jobs stop '
      'when this session exits.';
}
