/// Converts process capabilities into the shared authorization policy and
/// enforces the selected filesystem profile for one invocation.
library;

import 'dart:io' show Platform, FileSystemException, Directory;
import 'capability_envelope.dart';
import 'command_approval_store.dart';
import 'command_prefix.dart';
import 'package:path/path.dart' as path;
import 'sandbox_home.dart';
import 'dart:convert' show jsonEncode;

import 'glob.dart' show fileGlobMatch;
import 'permissions.dart';
import 'tools_plugin_surface.dart';
import 'process_runner.dart';
import 'read_only_commands.dart';
import 'read_directories.dart';
import 'os_sandbox_runner.dart';
import 'package:tina_mode/tina_mode.dart'
    show
        PermissionAccessOperation,
        AuthorizationRequest,
        AccessRequirement,
        AccessCapability;

/// The session mode a [SandboxedProcessRunner] enforces. Re-exported from
/// the permissions vocabulary so callers need one import less.
export 'permissions.dart' show PermissionMode;

/// Session-scoped "always" answers, remembered as permissions on exact structured
/// commands — the twin of `FileGrants`, but there is no sibling-glob trick here:
/// a command line has no directory to widen into, and widening `"git
/// status"` to `"git *"` would silently approve a tree of unrelated
/// commands. A host may remember a prefix glob deliberately (see
/// [CommandGrants.rememberPattern]).
///
/// Sessions are in-memory by design: grants die with the object, so nothing
/// outlives the run that approved it.
final class CommandGrants implements ToolCommandGrants {
  final List<String> _patterns = [];
  final Set<String> _exactLines = {};
  final Map<
      String,
      ({
        String identity,
        String line,
        Set<ProcessPermission> permissions,
        ProcessDirectoryAccess directoryAccess
      })> _requests = {};

  static String _key(ProcessRequest request) {
    final environment = request.environment;
    final names = environment?.keys.toList()?..sort();
    return jsonEncode([
      request.command,
      request.arguments,
      request.workingDirectory,
      // Map insertion order is not part of the command's permission scope.
      // Null still differs from an empty map: it inherits the host environment.
      if (names == null)
        null
      else
        {for (final name in names) name: environment![name]},
      request.stdin,
    ]);
  }

  void rememberRequest(
    ProcessRequest request, {
    Set<ProcessPermission> permissions = const {
      ProcessPermission.execution,
      ProcessPermission.workspaceWrite
    },
    ProcessDirectoryAccess directoryAccess =
        const ProcessDirectoryAccess.empty(),
  }) {
    if (permissions.isEmpty) return;
    final identity = _key(request);
    final key = jsonEncode([identity, directoryAccess.toJson()]);
    final grant = _requests.putIfAbsent(
        key,
        () => (
              identity: identity,
              line: lineOf(request),
              permissions: <ProcessPermission>{},
              directoryAccess: directoryAccess
            ));
    grant.permissions.addAll(permissions);
  }

  bool coversRequest(
    ProcessRequest request, {
    ProcessPermission permission = ProcessPermission.execution,
    ProcessDirectoryAccess directoryAccess =
        const ProcessDirectoryAccess.empty(),
  }) =>
      _requests.values.any((grant) =>
          grant.identity == _key(request) &&
          (grant.permissions.contains(permission) ||
              permission == ProcessPermission.workspaceWrite &&
                  grant.permissions.contains(ProcessPermission.unconfined)) &&
          grant.directoryAccess.covers(directoryAccess)) ||
      // Legacy line/pattern grants authorize writable execution, never network/host.
      ({ProcessPermission.execution, ProcessPermission.workspaceWrite}
              .contains(permission) &&
          patternFor(lineOf(request)) != null);

  /// Human-readable labels for explicit grants and approved requests.
  List<String> get patterns => List.unmodifiable([
        ..._exactLines,
        ..._patterns,
        ..._requests.values.map((grant) => grant.line)
      ]);

  bool get isEmpty => patterns.isEmpty;
  int get length => patterns.length;

  /// The command line this request is remembered as: program joined with its
  /// arguments by single spaces. Used for display and explicit pattern grants;
  /// automatic approvals use the structured request identity.
  static String lineOf(ProcessRequest request) =>
      [request.command, ...request.arguments].join(' ');

  /// Remembers one exact command line. Returns false if it was already
  /// present (idempotent, mirroring `FileGrants.remember`).
  bool remember(String commandLine) {
    return _exactLines.add(commandLine);
  }

  /// Remembers a glob (a `fileGlobMatch` pattern, e.g. `'git status'` or the
  /// wider `'git *'`). A host's deliberate widening; the runner itself only
  /// ever calls [rememberRequest].
  bool rememberPattern(String glob) {
    if (_patterns.contains(glob)) return false;
    _patterns.add(glob);
    return true;
  }

  /// The first pattern that matches [commandLine], or null.
  String? patternFor(String commandLine) {
    if (_exactLines.contains(commandLine)) return commandLine;
    for (final pattern in _patterns) {
      if (fileGlobMatchCommand(pattern, commandLine)) return pattern;
    }
    return null;
  }
}

/// Glob-match a command line. Delegates to the path glob (`fileGlobMatch`):
/// a command line is just a string, `*` spanning spaces is exactly what a
/// command grant wants (`'git *'` → `'git status --porcelain'`), and two
/// glob dialects for one concept would be one more thing to keep in step.
bool fileGlobMatchCommand(String pattern, String commandLine) =>
    fileGlobMatch(pattern, commandLine);

/// A [ProcessRunner] that enforces the command × mode table before any
/// process exists.
///
/// The wrapped [inner] runner only ever sees requests the boundary allowed —
/// read-only execution additionally requires a [ConfinedProcessRunner].
/// Policy is resolved here; the inner backend enforces filesystem confinement.
final class SandboxedProcessRunner
    implements ProcessRunner, ToolProcessRunnerView {
  /// The runner that actually starts processes. Only allowed requests
  /// reach it.
  final ProcessRunner inner;

  /// The session mode. Mutable, like `SandboxedFileSystem.mode`: the same
  /// tool flips behavior when the host flips the mode.
  PermissionMode mode;

  /// The session's writable directories — paths a command may create or
  /// modify. Used to explain an approval request; these are not execution grants.
  final WritableDirectories writableDirectories;

  /// Whether the session lets commands reach the network. Off by default:
  /// a command that appears to need network asks.
  final bool networkOff;

  /// The approver — the same object the filesystem takes. Nothing wired means
  /// deny: fail closed.
  Approver? approver;

  /// Reviews the whole command once for all missing permissions.
  ProcessCommandApprover? commandApprover;

  /// Session grants remembered from "always" answers.
  final CommandGrants grants;

  /// PATH used by the inner runner. Certified readers are pinned to their
  /// verified absolute executable, while all reviewed commands stay verbatim.
  final String? executableSearchPath;
  final ReadOnlyDirectories? readDirectories;
  final String? workspaceRoot;
  final SandboxPlan? plan;
  final CommandApprovalStore? approvalStore;
  Map<String, String> Function()? trustedReaderExecutables;

  /// The sandbox fast path lookup: files this session's own write/edit
  /// tools created (decision_pipeline.dart). Null disables the path.
  bool Function(String path)? agentCreated;
  bool Function(String)? outputWritePermission;
  bool Function(ProcessRequest, ProcessPermission, ProcessDirectoryAccess)?
      persistentPermission;
  Future<bool> Function(ProcessRequest, SandboxAccessRequest, bool retry,
      bool Function() isActive)? directoryApprover;

  bool Function()? workspaceWriteGranted;
  Future<bool> Function()? requestWorkspaceWrite;
  bool _workspaceWrites = false;

  SandboxedProcessRunner({
    required this.inner,
    this.mode = PermissionMode.approve,
    WritableDirectories? writableDirectories,
    this.networkOff = true,
    this.approver,
    this.commandApprover,
    CommandGrants? grants,
    this.executableSearchPath,
    this.readDirectories,
    this.workspaceRoot,
    this.plan,
    this.approvalStore,
  })  : writableDirectories = writableDirectories ?? WritableDirectories(),
        grants = grants ?? CommandGrants();

  @override
  Future<RunOutcome> run(ProcessRequest request,
      {ProcessControl? control}) async {
    var cancelled = false;
    control?.whenCancelled?.then((_) {
      cancelled = true;
    });
    // The reviewed identity and the spawned command must remain identical
    // while an asynchronous approval is pending.
    request = (
      command: request.command,
      arguments: List.unmodifiable(request.arguments),
      workingDirectory: request.workingDirectory,
      environment: request.environment == null
          ? null
          : Map.unmodifiable(request.environment!),
      stdin: request.stdin,
      timeout: request.timeout,
    );
    control = control?.copyWith(
        readOnly: false,
        workspaceWriteAllowed: false,
        networkAllowed: false,
        outsideSandboxAllowed: false,
        clearEnvironmentApproval: true,
        outputDirectories: const [],
        readDirectories: List.unmodifiable(control.readDirectories),
        writeDirectories: List.unmodifiable(control.writeDirectories),
        clearDirectoryApproval: true);
    if (cancelled || control?.isCancelled?.call() == true) {
      return const CommandRefused('cancelled: command was not started');
    }
    final outsideSandbox = control?.outsideSandboxRequested ?? false;
    final confined = inner is ConfinedProcessRunner &&
        (inner as ConfinedProcessRunner).confinesFilesystem;
    if (plan != null) {
      request = (
        command: request.command,
        arguments: request.arguments,
        workingDirectory: request.workingDirectory,
        environment: Map<String, String>.unmodifiable(
            outsideSandbox || !confined
                ? plan!.outsideEnvironment
                : plan!.childEnvironment),
        stdin: request.stdin,
        timeout: request.timeout,
      );
    }
    final searchPath = request.environment?['PATH'] ?? executableSearchPath;
    if (outsideSandbox && (control?.sandboxReason?.trim().isEmpty ?? true)) {
      return const CommandRefused(
          'A sandbox_reason is required for outside-sandbox execution.');
    }
    // No OS confinement also means no OS network isolation. Ask for that
    // access explicitly rather than pretending the offline restriction holds.
    if (outsideSandbox && plan != null) {
      try {
        final environment = request.environment!;
        request = (
          command: resolveHostExecutable(request,
              workspace: plan!.workspaceRoot, searchPath: environment['PATH']),
          arguments: request.arguments,
          workingDirectory: canonicalSandboxPath(
              request.workingDirectory ?? plan!.workspaceRoot),
          environment: environment,
          stdin: request.stdin,
          timeout: request.timeout,
        );
      } on FileSystemException catch (error) {
        return CommandRefused('Cannot prepare host command: $error');
      }
    }
    final network = (control?.networkRequested ?? false) || outsideSandbox;
    final root =
        canonicalSandboxPath(workspaceRoot ?? request.workingDirectory ?? '.');
    bool inside(String target) =>
        sandboxPathUnder(canonicalSandboxPath(target), root);
    final envelope = CapabilityEnvelope.parse(request,
        filteredEnvironment: plan != null,
        control: control,
        searchPath: searchPath,
        canWrite: outputWritePermission);
    final ProcessDirectoryAccess access;
    try {
      access = _directoryRequirements(envelope, request, control,
          infer: !outsideSandbox);
    } on FormatException catch (error) {
      return CommandRefused(error.message);
    } on FileSystemException {
      return const CommandRefused('Cannot resolve requested path access');
    }
    final accessIdentity = jsonEncode(access.toJson());
    final cwdIdentity = canonicalSandboxPath(request.workingDirectory ?? root);
    bool accessUnchanged() {
      try {
        return canonicalSandboxPath(
                    workspaceRoot ?? request.workingDirectory ?? '.') ==
                root &&
            canonicalSandboxPath(request.workingDirectory ?? root) ==
                cwdIdentity &&
            jsonEncode(_directoryRequirements(envelope, request, control,
                        infer: !outsideSandbox)
                    .toJson()) ==
                accessIdentity;
      } on Object {
        return false;
      }
    }

    final writesRequested = control?.readOnlyRequested == false ||
        access.write.any(inside) ||
        envelope.writes.any(inside);
    if (control?.readOnlyRequested == true && access.write.isNotEmpty) {
      return const CommandRefused(
          'Read-only access cannot include write paths.');
    }
    bool workspaceAllowed() =>
        mode == PermissionMode.yolo ||
        (workspaceWriteGranted?.call() ?? _workspaceWrites);
    if (writesRequested &&
        !workspaceAllowed() &&
        requestWorkspaceWrite != null) {
      if (!await requestWorkspaceWrite!()) {
        return const CommandRefused('Workspace writes were not approved.');
      }
    }
    if (cancelled || control?.isCancelled?.call() == true) {
      return const CommandRefused('cancelled: command was not started');
    }
    final readOnly = control?.readOnlyRequested == true ||
        !outsideSandbox &&
            confined &&
            !writesRequested &&
            !workspaceAllowed() &&
            access.write.isEmpty &&
            !(plan?.pathGrants?.grants
                    .any((g) => g.write && g.covers(g.path, write: true)) ??
                false);
    if (readOnly && (!confined || outsideSandbox)) {
      return const CommandRefused(
          'Read-only execution requires an available OS sandbox.');
    }
    String executable;
    try {
      executable = resolveHostExecutable(request,
          workspace: root, searchPath: searchPath);
    } on FileSystemException {
      executable = request.command;
    }
    final deletions =
        _deletionTargets(request, request.workingDirectory ?? root);
    final prefixPlan = CommandPrefixPlan.parse(request,
        workspace: root,
        sandboxHomeRoot:
            confined && !outsideSandbox ? plan?.home?.stateRoot : null,
        searchPath: request.environment?['PATH'] ?? executableSearchPath);
    final rememberedCapabilities = <String>{};
    bool prefixGranted(String capability) {
      final covered =
          approvalStore?.coversPrefixes(prefixPlan, capability) ?? false;
      if (covered) rememberedCapabilities.add(capability);
      return covered;
    }

    final requirements = <AccessRequirement>[
      AccessRequirement(AccessCapability.execute, executable,
          granted: prefixGranted('execute'),
          workspace: path.isAbsolute(executable) &&
              inside(executable) &&
              !outsideSandbox),
      if (writesRequested || workspaceAllowed())
        AccessRequirement(AccessCapability.write, root,
            workspace: true, granted: workspaceAllowed()),
      if (network)
        AccessRequirement(AccessCapability.network, executable,
            granted: prefixGranted('network')),
      if (outsideSandbox || !confined)
        AccessRequirement(AccessCapability.host, executable,
            granted: prefixGranted('host')),
      for (final target in access.read)
        AccessRequirement(AccessCapability.read, target,
            workspace: inside(target), granted: _canRead(target)),
      for (final target in access.write)
        AccessRequirement(AccessCapability.write, target,
            workspace: inside(target),
            granted: inside(target)
                ? workspaceAllowed()
                : plan?.canWrite(target) == true),
      for (final target in deletions)
        AccessRequirement(AccessCapability.delete, target,
            workspace: inside(target),
            granted: inside(target) && workspaceAllowed()),
    ];
    final authorization = AuthorizationRequest(
        requirements: requirements,
        readOnlyExecution: readOnly,
        confined: confined);
    final missing = authorization.uncovered(mode);
    final requiredPermissions = <ProcessPermission>{
      ProcessPermission.execution,
      if (writesRequested || workspaceAllowed())
        ProcessPermission.workspaceWrite,
      if (network) ProcessPermission.network,
      if (outsideSandbox || !confined) ProcessPermission.unconfined,
      if (!access.isEmpty) ProcessPermission.directoryAccess,
    };
    const reason =
        'Approve the executable and requested access outside the workspace.';
    if (missing.isNotEmpty && mode != PermissionMode.yolo) {
      final approve = commandApprover;
      if (approve == null)
        return const CommandRefused('No command approver is configured.');
      final answer = approve(
          request,
          CommandApproval(
              reason: reason,
              authorization: authorization,
              requiredPermissions: requiredPermissions,
              missingPermissions: requiredPermissions,
              directoryAccess: access,
              networkReason: control?.networkReason,
              sandboxReason: control?.sandboxReason,
              isActive: () =>
                  !cancelled &&
                  control?.isCancelled?.call() != true &&
                  accessUnchanged()));
      final result = await (control?.whenCancelled == null
          ? answer
          : Future.any([
              answer,
              control!.whenCancelled!.then((_) => Approval.no),
            ]));
      if (result == Approval.no ||
          cancelled ||
          control?.isCancelled?.call() == true) {
        return const CommandRefused(
            'Access denied or cancelled; command was not started.');
      }
      if (writesRequested && requestWorkspaceWrite == null)
        _workspaceWrites = true;
    }
    if (!accessUnchanged() ||
        rememberedCapabilities.any((capability) =>
            approvalStore?.coversPrefixes(prefixPlan, capability) != true) ||
        prefixPlan != null &&
            CommandPrefixPlan.parse(request,
                        workspace: root,
                        sandboxHomeRoot: confined && !outsideSandbox
                            ? plan?.home?.stateRoot
                            : null,
                        searchPath: request.environment?['PATH'] ??
                            executableSearchPath)
                    ?.identity !=
                prefixPlan.identity ||
        plan?.validDirectoryAccess(access, linux: _linux) == false) {
      return const CommandRefused('Requested paths changed during approval.');
    }
    if (path.isAbsolute(executable) &&
        canonicalSandboxPath(executable) != executable) {
      return const CommandRefused('Executable changed during approval.');
    }
    final authorized = (control ?? const ProcessControl()).copyWith(
      readOnly: readOnly,
      workspaceWriteAllowed:
          workspaceAllowed() && control?.readOnlyRequested != true,
      networkAllowed: network,
      outsideSandboxAllowed: outsideSandbox,
      outputDirectories: const [],
      approvedDirectories: access,
      approvedHostEnvironment: outsideSandbox ? request.environment : null,
      approvedEnvironment: plan == null ? null : request.environment,
    );
    final outcome = await inner.run((
      command: executable,
      arguments: request.arguments,
      workingDirectory: request.workingDirectory,
      environment: request.environment,
      stdin: request.stdin,
      timeout: request.timeout,
    ), control: authorized);
    // An undeclared access remains a blocked result. Retrying is a new tool
    // request: a command may already have produced side effects.
    return _completed(
        outcome, 'Allowed by resource grants and invocation approval');
  }

  List<String> _deletionTargets(ProcessRequest request, String cwd) {
    final parts = literalShellParts(request);
    final commands = parts == null
        ? [
            [request.command, ...request.arguments]
          ]
        : parts.map((p) => p.words);
    return [
      for (final words in commands)
        if (words.isNotEmpty &&
            {'rm', 'rmdir', 'unlink'}.contains(path.basename(words.first)))
          for (final operand in words.skip(1).where((a) => !a.startsWith('-')))
            canonicalSandboxPath(
                path.isAbsolute(operand) ? operand : path.join(cwd, operand)),
    ];
  }

  bool get _linux => inner is OsSandboxRunner
      ? (inner as OsSandboxRunner).backend == SandboxBackend.bwrap
      : Platform.isLinux;

  bool _canRead(String value) =>
      plan?.canRead(value,
          backend: inner is OsSandboxRunner
              ? (inner as OsSandboxRunner).backend
              : null) ==
      true;

  ProcessDirectoryAccess _directoryRequirements(CapabilityEnvelope envelope,
      ProcessRequest request, ProcessControl? control,
      {required bool infer}) {
    final read = <String>[...?control?.readDirectories];
    final write = <String>[...?control?.writeDirectories];
    final plan = this.plan;
    if (plan == null) {
      if (read.isNotEmpty || write.isNotEmpty) {
        throw const FormatException('Directory access requires a sandbox plan');
      }
      return const ProcessDirectoryAccess.empty();
    }
    final cwd = request.workingDirectory ?? workspaceRoot ?? plan.workspaceRoot;
    void add(String target, bool writable) {
      if (writable ? plan.canWrite(target, linux: _linux) : _canRead(target))
        return;
      if (!plan.canGrant(target, write: writable, linux: _linux)) return;
      var directory =
          Directory(target).existsSync() ? target : path.dirname(target);
      while (!Directory(directory).existsSync()) {
        final parent = path.dirname(directory);
        if (parent == directory) return;
        directory = parent;
      }
      if (directory == path.separator ||
          plan.hostHome != null &&
              directory == canonicalSandboxPath(plan.hostHome!) ||
          !plan.canGrant(directory, write: writable, linux: _linux)) return;
      (writable ? write : read).add(directory);
    }

    final confined = inner is ConfinedProcessRunner &&
        (inner as ConfinedProcessRunner).confinesFilesystem;
    if (infer && confined) {
      if (!sandboxPathUnder(canonicalSandboxPath(cwd),
          canonicalSandboxPath(plan.workspaceRoot))) {
        add(canonicalSandboxPath(cwd), false);
      }
      for (final access in envelope.verifiedAccesses) {
        add(access.path, access.operation != PermissionAccessOperation.read);
      }
      if ({'touch', 'mkdir'}.contains(path.basename(request.command)) &&
          request.arguments.every((arg) =>
              !arg.startsWith('-') ||
              arg == '--' ||
              path.basename(request.command) == 'mkdir' && arg == '-p')) {
        for (final argument
            in request.arguments.where((arg) => !arg.startsWith('-'))) {
          add(
              canonicalSandboxPath(path.isAbsolute(argument)
                  ? argument
                  : path.join(cwd, argument)),
              true);
        }
      }
    }
    return plan.resolveDirectoryAccess(
        read: read.toSet(), write: write.toSet(), cwd: cwd, linux: _linux);
  }

  /// The inner runner may refuse (a host-enforced seam) or report an
  /// OS-sandbox denial ([CommandBlocked]); neither may be masked as an
  /// ordinary completed run. A completed run gains the decision's note.
  static RunOutcome _completed(RunOutcome inner, String note) =>
      switch (inner) {
        CommandCompleted(
          :final exitCode,
          :final stdout,
          :final stderr,
          :final cancelled,
          :final timedOut
        ) =>
          CommandCompleted(
              exitCode: exitCode,
              stdout: stdout,
              stderr: stderr,
              note: inner.note ?? note,
              cancelled: cancelled,
              timedOut: timedOut),
        CommandRefused() => inner,
        CommandBlocked() => inner,
        CommandRunning() => inner,
      };
}

/// The session's writable directories, and the one heuristic that keeps the table
/// honest: which requests provably stay inside them.
///
/// **Provably is the operative word.** A command string cannot be classified,
/// so for `bash` there is no proof, and unprovable means ask (or refuse in
/// `readOnly`). Only argv-shaped requests — what `exec` builds — can be
/// judged: their absolute file arguments are checked against the
/// directories, their cwd must sit inside them, and anything path-shaped
/// but unresolved asks.
///
/// This is a gate on arguments, not a boundary on behaviour. There is no
/// OS-level sandbox behind it — no `bwrap`, no `sandbox-exec` — so a
/// command that passes may still write anywhere once it starts.
final class WritableDirectories {
  final List<String> _roots;
  final bool Function(String)? permits;

  WritableDirectories([List<String>? roots])
      : _roots = List.of(roots ?? const []),
        permits = null;

  WritableDirectories.withPolicy(List<String> roots, {required this.permits})
      : _roots = List.of(roots);

  /// The roots, oldest first. Unmodifiable view.
  List<String> get roots => List.unmodifiable(_roots);

  /// Adds a writable root (a directory path). The project root is added by
  /// the tool wiring; a host may add more (`/tmp/build`).
  void add(String root) {
    if (!_roots.contains(root)) _roots.add(root);
  }

  void replace(Iterable<String> roots) {
    _roots
      ..clear()
      ..addAll(roots.toSet());
  }

  bool contains(String path) =>
      permits?.call(path) ?? _roots.any((r) => _isUnder(path, r));

  /// Whether this grant covers [request]: checks the working directory, and
  /// the arguments that are path-shaped — where path-shaped means starting
  /// with `/`, `./` or `../`, or being exactly `.` or `..`. A bare relative
  /// token like `etc/passwd` and an option-embedded path like
  /// `--out=../../x` are not path-shaped and therefore not judged. It says
  /// nothing about what the program does once it runs.
  bool covers(ProcessRequest request) {
    final cwd = request.workingDirectory;
    if (cwd != null && !contains(cwd)) return false;
    // No cwd and no path-shaped argument: nothing here names a place outside
    // the directories. The command itself is still unclassified — this only
    // means the *arguments* give no reason to ask.
    for (final a in request.arguments) {
      if (!_argumentInsideRoots(a)) return false;
    }
    return true;
  }

  /// One argument is inside the writable directories when it is not
  /// path-shaped, or is path-shaped and resolves inside. Absolute paths are
  /// judged directly; relative paths are judged against the cwd (already
  /// checked).
  bool _argumentInsideRoots(String argument) {
    if (!_isPathShaped(argument)) return true;
    if (argument.startsWith('/')) return contains(argument);
    // Relative and path-shaped: relative to the (already-checked) cwd, so
    // it cannot escape without the cwd check failing first. Keep it simple
    // and refuse to certify anything starting with `..` — that asks.
    return !argument.startsWith('..');
  }

  /// Cheap shape test — not a claim that the file exists. A token counts as
  /// path-shaped when it starts with `/`, `./` or `../`, or is exactly `.`
  /// or `..`. A bare relative token like `etc/passwd` is not path-shaped,
  /// and neither is an option-embedded path like `--out=../../x` — those
  /// are not judged here.
  static bool _isPathShaped(String token) =>
      token.startsWith('/') ||
      token.startsWith('./') ||
      token.startsWith('../') ||
      token == '.' ||
      token == '..';
}

/// True when [request] appears to need network access.
///
/// Heuristic on purpose, and it only ever errs toward asking: nothing here
/// can *prove* a program is offline, so the rule is "if it looks like it
/// wants the network, it asks". What cannot be allowed silently is a fetch
/// shaped request; a `curl`/`wget` in the program name or arguments, an
/// `http(s)://` URL anywhere in argv, or a known push/pull-shaped git
/// subcommand all look like network.
bool needsNetwork(ProcessRequest request) {
  final line = CommandGrants.lineOf(request);
  if (_networkPrograms.contains(request.command)) return true;
  if (line.contains('://')) return true;
  if (request.command == 'git' && request.arguments.isNotEmpty) {
    const netSubcommands = {'push', 'pull', 'fetch', 'clone', 'remote'};
    if (netSubcommands.contains(request.arguments.first)) return true;
  }
  return false;
}

const _networkPrograms = {
  'curl',
  'wget',
  'ssh',
  'scp',
  'rsync',
  'ping',
  'nc',
  'netcat',
  'ftp',
  'dig',
  'nslookup',
  'host',
  'telnet',
};

/// True when [child] is [parent] or lies under it — same discipline as the
/// filesystem's helper, so `/tmp/x` is not "under" `/tmp/xy`.
bool _isUnder(String child, String parent) {
  String trail(String path) => path.endsWith('/') ? path : '$path/';
  final c = trail(child == '' ? '/' : child);
  final par = trail(parent == '' ? '/' : parent);
  return c == par || c.startsWith(par);
}
