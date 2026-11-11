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
    implements ModeControl, ToolSessionSource, ToolsPluginSurface {
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
    PermissionMode mode = PermissionMode.approve,
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
    pathGrants = approvalStore is ResourceApprovalStore
        ? approvalStore.paths
        : PathGrants(
            file: File(path.join(workspaceRoot, '.tina', 'permissions.json')));
    readDirectories = ReadOnlyDirectories(
        source: () => [
              for (final g in pathGrants.grants)
                if (g.recursive && !g.write && g.covers(g.path)) g.path,
            ]);
    writeDirectories = WriteDirectories(
        source: () => [
              for (final g in pathGrants.grants)
                if (g.recursive && g.write && g.covers(g.path, write: true))
                  g.path,
            ]);
    commandApprovals = approvalStore is ResourceApprovalStore
        ? approvalStore
        : ResourceApprovalStore(
            paths: pathGrants,
            workspace: workspaceRoot,
            file: approvalStore != null
                ? approvalStore.file
                : realHome == null
                    ? null
                    : File(path.join(
                        realHome, '.tina', 'approvals', 'commands.json')),
            searchPath: SandboxPlan.defaultSearchPath,
          );
    osPlan = SandboxPlan(
      pathGrants: pathGrants,
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
    processRunner.outputWritePermission = (target) =>
        osPlan.canWrite(target) &&
        (!sandboxPathUnder(target, workspaceRoot) ||
            this
                .modePolicy
                .hasWorkspaceWriteGrant(canonicalSandboxPath(workspaceRoot)));
    processJobs = ProcessJobs(processRunner);
    this.modePolicy.listen((value) {
      if (sandbox.mode != value) processJobs.cancelAll(runningOnly: true);
      sandbox.mode = value;
      processRunner.mode = value;
    });
    sandbox.mode = this.modePolicy.mode;
    processRunner.mode = this.modePolicy.mode;
    processRunner.agentCreated = agentCreated;
    toolList = [
      LsTool(workspaceRoot: workspaceRoot, sandbox: sandbox),
      ReadTool(fs: sandbox, workspaceRoot: workspaceRoot),
      WriteTool(
          fs: sandbox,
          workspaceRoot: workspaceRoot,
          scratchNoticeFor: _scratchNoticeFor),
      EditTool(
          fs: sandbox,
          workspaceRoot: workspaceRoot,
          scratchNoticeFor: _scratchNoticeFor),
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
    var migratedDirectories = false;
    void applyDirectories() {
      List<String> granted(SettingDefinition<List<String>> definition) => [
            for (final scope in SettingScope.values)
              ...((settings?.override(definition, scope) as List?)
                      ?.cast<String>() ??
                  const <String>[]),
          ];
      if (!migratedDirectories && pathGrants.file?.existsSync() != true) {
        for (final directory in granted(readOnlyDirectoriesSetting)) {
          pathGrants.remember(directory, write: false, recursive: true);
        }
        for (final directory in granted(writeDirectoriesSetting)) {
          pathGrants.remember(directory, write: true, recursive: true);
        }
      }
      migratedDirectories = true;
      readDirectories.replace(const []);
      writeDirectories.replace(const []);
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
    this.modePolicy.saveAccessGrant = (capability, target, decision) {
      // This hook is used only by MCP; file/command grants use pathGrants.
      commandApprovals.rememberAccess(
          capability,
          target,
          decision == ApprovalDecision.allowAlways
              ? CommandApprovalScope.session
              : decision == ApprovalDecision.allowGlobal
                  ? CommandApprovalScope.global
                  : CommandApprovalScope.workspace);
    };
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

  late final PathGrants pathGrants;

  /// The scratch notice for a resolved write target, when the target is
  /// session scratch (a sandbox-home generation or its TMPDIR). Null when
  /// no sandbox home exists (no OS sandbox) or the target is durable.
  String? _scratchNoticeFor(String target) {
    final root = home?.stateRoot;
    if (root == null) return null;
    return scratchPathNotice(target,
        sandboxHomesRoot: root,
        tmpdir: path.join(home!.existingPath ?? '', 'tmp'));
  }

  void Function()? _stopHomeSettings;
  final ScopedSettings? settings;
  late final ReadOnlyDirectories readDirectories;
  late final WriteDirectories writeDirectories;
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
    pathGrants.remember(directory,
        write: false, recursive: true, persist: scope != SettingScope.session);
  }

  void rememberWriteDirectory(String directory, {SettingScope? scope}) {
    pathGrants.remember(directory,
        write: true, recursive: true, persist: scope != SettingScope.session);
    processRunner.writableDirectories.replace(osPlan.writableLayout());
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
        // The agent-script fast path: remember files this session's own
        // write/edit tools created. Running one's own script inside the
        // sandbox (workspace and temp) needs no execution question; the
        // sandbox holds it there.
        if (name == 'write' || name == 'edit') {
          final target = input['filePath'];
          if (target is String) _agentCreatedFiles.add(_absolute(target));
        }
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

  final _agentCreatedFiles = <String>{};

  String _absolute(String target) =>
      target.startsWith('/') ? target : '$workingDirectory/$target';

  /// Did this session's own write/edit tools create (or last write)
  /// [path]? Used by the agent-script fast path in the decision pipeline.
  bool agentCreated(String path) => _agentCreatedFiles.contains(path);

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
    c.promptSections.add(
        'Workspace writes: ${modePolicy.hasWorkspaceWriteGrant(canonicalSandboxPath(workingDirectory)) ? 'approved for this session' : 'not yet approved'}.');
    for (final grant in pathGrants.grants) {
      c.promptSections.add(
          'Human-approved ${grant.write ? 'read/write' : 'read'} ${grant.recursive ? 'directory' : 'file'}: ${grant.path}');
    }
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

  /// The resource permissions communicated to the acting model.
  String sectionFor(PermissionMode mode) =>
      'Working directory: $workingDirectory. Mode: ${mode.normalized.label}. '
      'Workspace reads are permitted. The first workspace write requires human '
      'approval for writes throughout this workspace for the session. '
      'External reads, writes and execution require approval unless a human path '
      'grant covers the requested read/write. Approve mode asks the user; auto '
      'mode reviews external access with a model that denies secret access and '
      'deletion outside the workspace. Saved read/write grants never authorize '
      'external execution or deletion. '
      'Use access: "workspace-write" for commands that modify workspace files. '
      'Use access: "read-only" to keep a command read-only even after a write '
      'grant. Specify read_directories or write_directories for external paths; '
      'these requested capabilities apply to one invocation. '
      'A blocked command may already have produced side effects. Request missing '
      'access explicitly before retrying; never automatically rerun it. '
      'Network requires network: true and network_reason and is reviewed with '
      'the command. No command family or command pattern bypasses review. '
      'Sandbox-private HOME and TMPDIR are temporary scratch; save deliverables '
      'in the workspace or another user-approved durable location. '
      'Host authentication requires outside_sandbox: true and sandbox_reason; '
      'these human-only requests grant host filesystem and network access to '
      'this invocation. Respect denied and cancelled approvals. '
      '${sandboxDescription?.call() ?? ''} '
      'Use background: true for long commands, and process to inspect or stop '
      'the returned job. Do not restart a live job.';
}
