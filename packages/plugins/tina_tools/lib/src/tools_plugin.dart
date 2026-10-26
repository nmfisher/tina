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
import 'package:path/path.dart' as path;

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tools/tina_tools.dart';
import 'package:tina_settings/tina_settings.dart';
import 'package:tina_approvals/tina_approvals.dart';

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
    this.settings,
    this.enableSpeculative = false,
    Map<String, String>? hostEnvironment,
    Directory? sandboxState,
    CommandApprovalStore? approvalStore,
    List<String> protectedPaths = const [],
  })  : modePolicy = modePolicy ?? ModePlugin(mode: mode),
        sandbox = SandboxedFileSystem(
          const IoFileSystem(),
          workspaceRoot: workspaceRoot,
          tinaDir: tinaDir,
          mode: mode,
        ) {
    final environment = hostEnvironment ?? Platform.environment;
    final realHome = environment['HOME'];
    home = realHome == null
        ? null
        : SandboxHome(
            realHome: canonicalSandboxPath(realHome),
            stateRoot: sandboxState?.path ??
                path.join(realHome, '.tina', 'sandbox-homes'),
          );
    commandApprovals = approvalStore ??
        CommandApprovalStore(
          workspace: workspaceRoot,
          file: realHome == null
              ? null
              : File(
                  path.join(realHome, '.tina', 'approvals', 'commands.json')),
          searchPath: SandboxPlan.defaultSearchPath,
        );
    osPlan = SandboxPlan(
      workspaceRoot: workspaceRoot,
      tinaDir: tinaDir.path,
      parentEnvironment: environment,
      home: home,
      protectedPaths: [
        ...protectedPaths,
        if (commandApprovals.file != null) commandApprovals.file!.parent.path
      ],
      isolateNetwork: osIsolateNetwork,
      readDirectories: readDirectories,
      writeDirectories: writeDirectories,
    );
    final writable = WritableDirectories.withPolicy(osPlan.writableLayout(),
        permits: osPlan.canWrite);
    sandbox.writeDirectories = writeDirectories;
    sandbox.protectedPath = osPlan.isProtected;
    sandbox.policyRevision = () => this.modePolicy.revision;
    final osRunner = OsSandboxRunner(
      inner: const IoProcessRunner(),
      plan: osPlan,
      enabled: osSandbox,
      unavailableBehaviour: osUnavailable,
    );
    sandbox.readablePath = (target) =>
        osPlan.canRead(target) ||
        settings?.read(allowReadsOutsideWorkspaceSetting).value == true;
    processRunner = SandboxedProcessRunner(
      inner: osRunner,
      mode: mode,
      writableDirectories: writable,
      executableSearchPath: osPlan.searchPath,
      readDirectories: readDirectories,
      workspaceRoot: workspaceRoot,
      plan: osPlan,
    );
    processRunner.trustedReaderExecutables =
        () => commandApprovals.readerExecutables;
    processRunner.outputWritePermission = (target) =>
        osPlan.canWrite(target) &&
        (!sandboxPathUnder(target, workspaceRoot) ||
            sandbox.mode == PermissionMode.allowEdits ||
            writeDirectories.allows(target));
    processRunner.persistentPermission = (request, permission, directories) =>
        (permission == ProcessPermission.directoryAccess &&
            directories.read.isNotEmpty &&
            directories.write.isEmpty &&
            settings?.read(allowReadsOutsideWorkspaceSetting).value == true) ||
        commandApprovals.covers(request, {permission},
            directoryAccess: permission == ProcessPermission.directoryAccess
                ? directories
                : const ProcessDirectoryAccess.empty());
    processJobs = ProcessJobs(processRunner);
    this.modePolicy.listen((value) {
      if (sandbox.mode != value) processJobs.cancelAll(runningOnly: true);
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
    _speculative = SpeculativeCache(
      defaults: const {
        'ls': {'maxResults': 200, 'all': false},
        'read': {'offset': 1, 'limit': 2000},
      },
    );
    _speculativePrefetch = SpeculativePrefetch(
        _speculative,
        {
          'ls': (input) =>
              toolList.firstWhere((t) => t.schema.name == 'ls').execute(input),
          'glob': (input) => toolList
              .firstWhere((t) => t.schema.name == 'glob')
              .execute(input),
          'stat': (input) => toolList
              .firstWhere((t) => t.schema.name == 'stat')
              .execute(input),
          'read': (input) => toolList
              .firstWhere((t) => t.schema.name == 'read')
              .execute(input),
        },
        enabled: () => enableSpeculative && !_closed);
    void applyDirectories() {
      List<String> granted(SettingDefinition<List<String>> definition) => [
            for (final scope in SettingScope.values)
              ...((settings?.override(definition, scope) as List?)
                      ?.cast<String>() ??
                  const <String>[]),
          ];
      readDirectories.replace(granted(readOnlyDirectoriesSetting));
      writeDirectories.replace(granted(writeDirectoriesSetting));
      writable.replace(osPlan.writableLayout());
    }

    if (settings != null) {
      _stopReadSettings = settings!.listen(applyDirectories);
      applyDirectories();
    }
    if (settings?.catalog.contains(homeCachesSetting.id) == true) {
      _stopHomeSettings = settings!.watch(homeCachesSetting, (value) {
        home?.replace(value.value);
        writable.replace(osPlan.writableLayout());
      }, fireImmediately: true);
    }
    this.modePolicy.hasAccessGrant = commandApprovals.coversAccess;
    this.modePolicy.saveAccessGrant =
        (capability, target, decision) => commandApprovals.rememberAccess(
            capability,
            target,
            switch (decision) {
              ApprovalDecision.allowWorkspace => CommandApprovalScope.workspace,
              ApprovalDecision.allowGlobal => CommandApprovalScope.global,
              _ => CommandApprovalScope.session,
            });
    this.modePolicy.persistentAccessGrants = commandApprovals.file != null;
    attachModePolicy(this);
    prompt = HostPromptSection(workingDirectory, () => sandbox.mode,
        sandboxDescription: osRunner.describeEnvironment);
  }

  /// The one configuration behind both the OS layout and the gate's
  /// writable directories. Exposed so a session report can name the plan;
  /// the plugin owns it, the host never touches it.
  late final SandboxPlan osPlan;
  late final CommandApprovalStore commandApprovals;
  late final SandboxHome? home;
  void Function()? _stopHomeSettings;
  final ScopedSettings? settings;
  final ReadOnlyDirectories readDirectories = ReadOnlyDirectories();
  final WriteDirectories writeDirectories = WriteDirectories();
  void Function()? _stopReadSettings;
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

  /// Read-only results, filled by [SpeculativePrefetch] during the
  /// prediction window and served by the wrapped executors in [mountOn].
  /// Cleared by any mutating executor and at turn end, so a hit is never
  /// older than the current turn's start.
  late final SpeculativeCache _speculative;
  late final SpeculativePrefetch _speculativePrefetch;

  /// Experimental prediction snapshots. Ordinary reads remain uncached.
  final bool enableSpeculative;
  bool _closed = false;

  Future<ToolResult?> _validateSpeculativeRead(
      String name, Map<String, Object?> input) async {
    try {
      final raw = name == 'read'
          ? requiredString(input, 'filePath')
          : name == 'stat'
              ? requiredString(input, 'path')
              : optionalString(input, 'path') ?? workingDirectory;
      await sandbox.guard(FileOp.read, resolveToolPath(raw, workingDirectory));
      return null;
    } on SandboxViolation catch (e) {
      return ToolResult.error(e.message);
    } on ToolValidationException catch (e) {
      return ToolResult.error(e.message);
    }
  }

  /// The prediction seam for slice 2: a plugin that predicts read-only
  /// calls submits them here during the turn's model-call window. Direct
  /// use only for tests and diagnostics.
  SpeculativePrefetch get speculativePrefetch => _speculativePrefetch;

  /// Hit/miss counters and live entry count, for diagnostics and for
  /// measuring whether prediction is earning its keep.
  SpeculativeStats get speculativeStats => _speculative.stats;
  ToolUse? _activeCall;

  void rememberReadDirectory(String directory, {SettingScope? scope}) {
    if (settings case final ScopedSettings settings) {
      scope ??= SettingScope.workspace;
      final paths = {
        ...((settings.override(readOnlyDirectoriesSetting, scope) as List?)
                ?.cast<String>() ??
            const <String>[]),
        directory
      }.toList();
      settings.set(readOnlyDirectoriesSetting, paths, scope);
    } else {
      readDirectories.replace({...readDirectories.paths, directory});
    }
  }

  void rememberWriteDirectory(String directory, {SettingScope? scope}) {
    if (settings case final ScopedSettings settings) {
      scope ??= SettingScope.workspace;
      final paths = {
        ...((settings.override(writeDirectoriesSetting, scope) as List?)
                ?.cast<String>() ??
            const <String>[]),
        directory
      }.toList();
      settings.set(writeDirectoriesSetting, paths, scope);
    } else {
      writeDirectories.replace({...writeDirectories.paths, directory});
      processRunner.writableDirectories.replace(osPlan.writableLayout());
    }
  }

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
    registerExecutors(loop.registerContextExecutor);
  }

  /// The tool dispatch, wired through a register callback. Split from
  /// [mountOn] so tests can capture the executors without an [AgentLoop]
  /// (the loop is final; the dispatch is the same code either way).
  void registerExecutors(
      void Function(String name, ContextToolExecutor exec) register) {
    for (final t in toolList) {
      final name = t.schema.name;
      final plain = enableSpeculative && speculativeTools.contains(name)
          ? (Map<String, Object?> input) => t.execute(input)
          : null;
      register(name, (input, context) async {
        settings?.reload();
        // A mutating tool's result cannot be trusted to leave the world
        // unchanged, whatever it reported: block caching during execution
        // and invalidate both before dispatch and after it settles.
        final invalidates = speculativeInvalidatingTools.contains(name);
        if (invalidates) _speculative.beginMutation();
        try {
          if (plain != null)
            return await _speculative.wrap(name, plain,
                validate: (input) => _validateSpeculativeRead(name, input),
                storeMisses: false,
                consume: true)(input);
          if (t is ProcessJobTool) {
            return await t.execute(input,
                control: ProcessControl(
                    isCancelled: context.isCancelled,
                    whenCancelled: context.whenCancelled,
                    whenInputPending: context.whenInputPending,
                    onOutput: context.report));
          }
          if (t is ProcessToolBase) {
            return await t.execute(input,
                control: ProcessControl(
                  isCancelled: context.isCancelled,
                  whenCancelled: context.whenCancelled,
                  whenInputPending: context.whenInputPending,
                  onOutput: context.report,
                ));
          }
          return await t.execute(input);
        } finally {
          if (invalidates) _speculative.endMutation();
        }
      });
    }
  }

  @override
  void onInput(TurnContext c) {
    _speculativePrefetch.cancel();
    _speculative.clear();
    modePolicy.onInput(c);
  }

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
    _speculativePrefetch.cancel();
    _speculative.clear();
    modePolicy.onTurnEnd(c);
  }

  @override
  void closeSession() {
    _closed = true;
    _speculativePrefetch.cancel();
    _stopReadSettings?.call();
    _stopHomeSettings?.call();
    _speculative.clear();
    unawaited(processJobs.close().whenComplete(() => home?.close()));
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
  void onPrompt(TurnContext c) {
    c.promptSections.add(prompt.sectionFor(sandbox.mode));
    if (writeDirectories.paths.isNotEmpty) {
      c.promptSections.add('User-approved writable directories: '
          '${writeDirectories.paths.join(', ')}. File tools may create and edit '
          'files within these directories without repeated write approval. '
          'Command execution still follows the current mode.');
    }
    if (readDirectories.paths.isNotEmpty) {
      c.promptSections.add('User-approved read-only directories: '
          '${readDirectories.paths.join(', ')}. File tools and commands using '
          'access: "read-only" may inspect these directories without repeated '
          'read approval. These grants never authorize writes, network or host execution.');
    }
  }
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
        PermissionMode.ask =>
          'workspace reads and enforced read-only commands or scripts run freely; workspace mutations require human approval; external access requires human approval',
        PermissionMode.readOnly =>
          'freely inspect, search and analyze anything inside the workspace using file tools, arbitrary commands or scripts; '
              'workspace and external mutations are blocked, including remembered write grants; '
              'execution uses an enforced read-only workspace profile; external reads and network require explicit human approval',
        PermissionMode.allowEdits =>
          'workspace reads, edits and confined commands or scripts run freely; external access requires explicit human approval',
        PermissionMode.auto =>
          'workspace reads and enforced read-only commands or scripts run freely; a safety judge reviews workspace mutations; external access requires explicit human approval',
        PermissionMode.yolo =>
          'requested capabilities are authorized by the yolo launch preset; configured OS confinement, protected paths and explicit Yes/No confirmations still apply',
      }}.\n\n'
      '${sandboxDescription?.call() ?? ''}\n\n'
      'Ordinary command approval does not change the OS confinement described '
      'above; it does not expose hidden paths or remove filesystem limits. '
      'For external task files or toolchains, request read_directories or '
      'write_directories on exec/bash. Name the narrowest existing directories; '
      'relative paths resolve from the invocation working directory. These '
      'capabilities are reviewed with the command and apply only to its '
      'subprocess tree, without changing later calls or network access. '
      'Known reader operands and simple touch/mkdir targets are gathered '
      'before review. Human folder grants can be remembered for the session, '
      'workspace or globally and reused by later commands and file tools. '
      'Sandboxed commands use a private HOME and private TMPDIR. Host caches are shared only when explicitly configured. '
      'Host credential files and authentication configuration are excluded. '
      'When host authentication is required, request outside_sandbox: true '
      'with sandbox_reason immediately: for example git push over SSH, ssh '
      'or scp using the host identity, or HTTPS using a host credential helper. '
      'Do not first attempt a command known to need unavailable credentials. '
      'Use the tool approval mechanism, not a request for the user to run it '
      'manually. Approved host execution uses the real HOME and filtered host '
      'environment, including SSH_AUTH_SOCK when available. It grants host '
      'filesystem and network access to this invocation and subprocess tree. '
      'Tina reuses matching human approvals for this session, workspace or '
      'globally; otherwise it asks the user, even in auto mode. Ordinary '
      'execution approval does not remove confinement. Global command '
      'approvals apply in any directory. Supported workspace test, build, '
      'analysis and formatting workflows cover project files and subdirectories; '
      'other session/workspace approvals retain the exact arguments and '
      'working directory. Host exceptions stay separate and exact. '
      'Do not retry unchanged or switch shells '
      'as a workaround. Respect denied or cancelled approvals.\n\n'
      'Use access: "read-only" on exec/bash for inspection and analysis with arbitrary '
      'commands or scripts. The OS sandbox blocks mutations; no command allowlist is required. '
      'With confinement available, ask, auto and read-only modes default to read-only access. '
      'Workspace file reads, git status, git log and other inspection need no user approval. '
      'Use access: "workspace-write" when a command must create, modify, rename or delete '
      'files, including tests or builds that write outputs or caches. Declaring '
      'write_directories also requests a writable profile for unrecognized commands '
      'unless access is explicit. '
      'Read-only mode refuses that profile. Other modes resolve it through '
      'the shared permission policy. Prefer dedicated file tools for ordinary edits. '
      'Access to paths outside the workspace, including reads through symlinks, requires an '
      'explicit human grant. Name read_directories or write_directories on the invocation. '
      'Network also requires an explicit human grant: set network: true and network_reason. '
      'Use working_directory to select the invocation directory. exec passes literal arguments; '
      'bash supports shell syntax. Changing syntax never changes the access policy. '
      'A blocked command may have partially run; an approved retry reruns the entire command.\n\n'
      'For long builds, servers and polling loops, set background: true on '
      'exec or bash, and set an appropriate timeout in seconds (default 600). '
      'This returns a job ID after approval and startup so you can handle other '
      'work. Use process to check status, wait with wait_ms, or cancel. Never '
      'restart a command that already has a live job. Background jobs stop '
      'when this session exits.';
}
