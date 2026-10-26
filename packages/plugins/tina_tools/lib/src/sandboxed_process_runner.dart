/// Converts process capabilities into the shared authorization policy and
/// enforces the selected filesystem profile for one invocation.
library;

import 'dart:io' show Platform, FileSystemException, Directory;
import 'command_approval_store.dart';
import 'package:path/path.dart' as path;
import 'sandbox_home.dart';
import 'dart:convert' show jsonEncode;

import 'glob.dart' show fileGlobMatch;
import 'permissions.dart';
import 'process_runner.dart';
import 'read_only_commands.dart';
import 'read_directories.dart';
import 'os_sandbox_runner.dart';
import 'command_workflow.dart';
import 'package:tina_mode/tina_mode.dart'
    show
        PermissionAccessOperation,
        AuthorizationRequest,
        AccessRequirement,
        AccessCapability,
        AuthorizationRoute,
        resolveAuthorization;

/// The session mode a [SandboxedProcessRunner] enforces. Re-exported from
/// the permissions vocabulary so callers need one import less.
export 'permissions.dart' show PermissionMode;

/// One policy rule, named so a reason can cite it. These are the words the
/// model reads in a refusal; keep them specific.
enum CommandRule {
  /// Execution requires approval even within writable directories.
  permissionMode,

  /// `readOnly`: workspace mutations and host execution are blocked.
  readOnly,

  /// A direct invocation of a verified system reader with supported options.
  readOnlyReader,

  /// The command provably reads, or creates/edits/moves/deletes, nothing
  /// outside the session's writable directories, and shows no sign of
  /// needing to reach the network while network is off.
  insideWritableSet,

  /// A session grant (`CommandGrants`) remembered for this exact command
  /// covers it.
  sessionGrant,

  /// The command might create, edit or delete something outside the
  /// writable directories, or needs to reach the network while network is
  /// off — the approver decides.
  outsideSession,

  /// A single collapsed shell string (`/bin/sh -c <string>`, the bash-tool
  /// shape). What the string does cannot be proven from argv — it may read,
  /// write, or reach the network anywhere — so it never rides the writable
  /// directories. Only separately certified literal readers may reuse a
  /// directory read grant; other strings ask.
  shellString,
}

/// Why the table landed where it did, in one plain phrase — the string a UI
/// shows and the model reads. Names the rule and, when it matters, the
/// first offending path.
String commandReason(CommandRule rule, ProcessRequest request) =>
    switch (rule) {
      CommandRule.permissionMode => 'allow command (${request.command})?',
      CommandRule.readOnly =>
        'allow command in read-only mode (${request.command})?',
      CommandRule.readOnlyReader =>
        'permitted read: verified command (${request.command})',
      CommandRule.insideWritableSet =>
        'command stays inside the session\'s writable directories '
            '(${request.command})',
      CommandRule.sessionGrant =>
        'allowed by session grant (${request.command})',
      CommandRule.outsideSession =>
        'allow command outside the session\'s writable directories '
            '(${request.command})?',
      CommandRule.shellString =>
        'allow a shell command string? what it runs cannot be checked '
            'against the writable directories (${request.arguments.join(' ')})',
    };

/// Session-scoped "always" answers, remembered as permissions on exact structured
/// commands — the twin of `FileGrants`, but there is no sibling-glob trick here:
/// a command line has no directory to widen into, and widening `"git
/// status"` to `"git *"` would silently approve a tree of unrelated
/// commands. A host may remember a prefix glob deliberately (see
/// [CommandGrants.rememberPattern]).
///
/// Sessions are in-memory by design: grants die with the object, so nothing
/// outlives the run that approved it.
final class CommandGrants {
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

/// One review of the entire action, including permissions already granted.
/// The answer authorizes only [missingPermissions]; Always stores those for
/// this structured command in this session.
final class CommandApproval {
  CommandApproval({
    required this.reason,
    required Set<ProcessPermission> requiredPermissions,
    required Set<ProcessPermission> missingPermissions,
    this.networkReason,
    this.sandboxReason,
    this.authorization,
    this.readDirectory,
    this.directoryAccess = const ProcessDirectoryAccess.empty(),
    bool Function()? isActive,
  })  : isActive = isActive ?? _alwaysActive,
        requiredPermissions = Set.unmodifiable(requiredPermissions),
        missingPermissions = Set.unmodifiable(missingPermissions);

  final String reason;
  final Set<ProcessPermission> requiredPermissions;
  final Set<ProcessPermission> missingPermissions;
  final AuthorizationRequest? authorization;
  final String? networkReason;
  final String? sandboxReason;
  final String? readDirectory;
  final ProcessDirectoryAccess directoryAccess;
  final bool Function() isActive;
  static bool _alwaysActive() => true;
}

/// A [ProcessRunner] that enforces the command × mode table before any
/// process exists.
///
/// The wrapped [inner] runner only ever sees requests the boundary allowed —
/// read-only execution additionally requires a [ConfinedProcessRunner].
/// Policy is resolved here; the inner backend enforces filesystem confinement.
final class SandboxedProcessRunner implements ProcessRunner {
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
  Future<Approval> Function(ProcessRequest, CommandApproval)? commandApprover;

  /// Session grants remembered from "always" answers.
  final CommandGrants grants;

  /// PATH used by the inner runner. Certified readers are pinned to their
  /// verified absolute executable, while all reviewed commands stay verbatim.
  final String? executableSearchPath;
  final ReadOnlyDirectories? readDirectories;
  final String? workspaceRoot;
  final SandboxPlan? plan;
  Map<String, String> Function()? trustedReaderExecutables;
  bool Function(String)? outputWritePermission;
  bool Function(ProcessRequest, ProcessPermission, ProcessDirectoryAccess)?
      persistentPermission;
  Future<bool> Function(ProcessRequest, SandboxAccessRequest, bool retry,
      bool Function() isActive)? directoryApprover;

  SandboxedProcessRunner({
    required this.inner,
    this.mode = PermissionMode.ask,
    WritableDirectories? writableDirectories,
    this.networkOff = true,
    this.approver,
    this.commandApprover,
    CommandGrants? grants,
    this.executableSearchPath,
    this.readDirectories,
    this.workspaceRoot,
    this.plan,
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
        outputDirectories: const [],
        readDirectories: List.unmodifiable(control.readDirectories),
        writeDirectories: List.unmodifiable(control.writeDirectories),
        clearDirectoryApproval: true);
    if (cancelled || control?.isCancelled?.call() == true) {
      return const CommandRefused('cancelled: command was not started');
    }
    final outsideSandbox = control?.outsideSandboxRequested ?? false;
    if (outsideSandbox && (control?.sandboxReason?.trim().isEmpty ?? true)) {
      return const CommandRefused(
          'A sandbox_reason is required for outside-sandbox execution.');
    }
    // No OS confinement also means no OS network isolation. Ask for that
    // access explicitly rather than pretending the offline restriction holds.
    if (outsideSandbox && plan != null) {
      try {
        final environment =
            Map<String, String>.unmodifiable(plan!.outsideEnvironment);
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
    final literal = literalShellRequest(request);
    final readerRequest = literal ?? request;
    var shellReader = readOnlyShellRequest(request,
        searchPath: executableSearchPath,
        trustedExecutables: trustedReaderExecutables?.call() ?? const {},
        canWrite: outputWritePermission);
    final candidate = readOnlyExecutable(readerRequest,
        searchPath: executableSearchPath,
        trustedExecutables: trustedReaderExecutables?.call() ?? const {});
    var reader = candidate;
    final ProcessDirectoryAccess declaredAccess;
    final ProcessDirectoryAccess explicitAccess;
    final ProcessDirectoryAccess directoryAccess;
    try {
      explicitAccess = _directoryRequirements(request, control, infer: false);
      declaredAccess =
          _directoryRequirements(request, control, infer: !outsideSandbox);
      directoryAccess = ProcessDirectoryAccess(
          read: declaredAccess.read.where((value) => !_canRead(value)),
          write: declaredAccess.write
              .where((value) => plan?.canWrite(value, linux: _linux) != true));
    } on FormatException catch (error) {
      return CommandRefused(error.message);
    } on FileSystemException {
      return const CommandRefused('Cannot resolve additional directory access');
    }
    bool directoriesUnchanged() {
      try {
        return (plan?.validDirectoryAccess(declaredAccess, linux: _linux) ??
                true) &&
            jsonEncode(_directoryRequirements(request, control, infer: false)
                    .toJson()) ==
                jsonEncode(explicitAccess.toJson());
      } on FileSystemException {
        return false;
      } on FormatException {
        return false;
      }
    }

    final confined = inner is ConfinedProcessRunner &&
        (inner as ConfinedProcessRunner).confinesFilesystem;
    final readOnlyProfile = control?.readOnlyRequested ??
        _defaultReadOnlyProfile(mode,
            confined: confined,
            certifiedReadOnly: reader != null || shellReader != null,
            writeRequested: declaredAccess.write.isNotEmpty);
    if (mode == PermissionMode.readOnly &&
        (!readOnlyProfile ||
            outsideSandbox ||
            declaredAccess.write.isNotEmpty)) {
      return const CommandRefused(
          'Read-only mode blocks workspace mutations, external writes and host execution.');
    }
    final requiredPermissions = {
      ProcessPermission.execution,
      if (!readOnlyProfile && !outsideSandbox) ProcessPermission.workspaceWrite,
      if (network) ProcessPermission.network,
      if (outsideSandbox || !confined) ProcessPermission.unconfined,
      if (!directoryAccess.isEmpty) ProcessPermission.directoryAccess,
    };
    final missing = requiredPermissions
        .where((permission) =>
            !(permission == ProcessPermission.execution &&
                (reader != null || shellReader != null)) &&
            persistentPermission?.call(request, permission, directoryAccess) !=
                true &&
            !grants.coversRequest(request,
                permission: permission, directoryAccess: directoryAccess))
        .toSet();
    bool granted(ProcessPermission permission) => !missing.contains(permission);
    final authorization = AuthorizationRequest(
      readOnlyExecution: readOnlyProfile && !outsideSandbox,
      confined: confined,
      requirements: [
        AccessRequirement(AccessCapability.execute, request.command,
            workspace: !outsideSandbox,
            granted: granted(ProcessPermission.execution) &&
                !(mode == PermissionMode.readOnly && !confined)),
        if (!readOnlyProfile && !outsideSandbox)
          AccessRequirement(AccessCapability.write,
              workspaceRoot ?? request.workingDirectory ?? '.',
              workspace: true,
              granted: granted(ProcessPermission.workspaceWrite)),
        if (network)
          AccessRequirement(AccessCapability.network, request.command,
              granted: granted(ProcessPermission.network)),
        if (outsideSandbox || !confined)
          AccessRequirement(AccessCapability.host, request.command,
              granted: granted(ProcessPermission.unconfined)),
        for (final directory in declaredAccess.read)
          AccessRequirement(AccessCapability.read, directory,
              workspace: workspaceRoot != null &&
                  sandboxPathUnder(directory, workspaceRoot!),
              granted: _canRead(directory) ||
                  granted(ProcessPermission.directoryAccess)),
        for (final directory in declaredAccess.write)
          AccessRequirement(AccessCapability.write, directory,
              workspace: workspaceRoot != null &&
                  sandboxPathUnder(directory, workspaceRoot!),
              granted: plan?.canWrite(directory, linux: _linux) == true ||
                  granted(ProcessPermission.directoryAccess)),
      ],
    );
    final uncovered = authorization.uncovered(mode);
    missing.removeWhere(
        (permission) => !uncovered.any((requirement) => switch (permission) {
              ProcessPermission.execution =>
                requirement.capability == AccessCapability.execute,
              ProcessPermission.workspaceWrite =>
                requirement.capability == AccessCapability.write &&
                    requirement.workspace,
              ProcessPermission.network =>
                requirement.capability == AccessCapability.network,
              ProcessPermission.unconfined =>
                requirement.capability == AccessCapability.host,
              ProcessPermission.directoryAccess => !requirement.workspace &&
                  {AccessCapability.read, AccessCapability.write}
                      .contains(requirement.capability),
            }));
    final resolution = resolveAuthorization(authorization, mode);
    if (resolution.route == AuthorizationRoute.deny) {
      return CommandRefused(resolution.reason);
    }
    final baseReason = !directoryAccess.isEmpty
        ? 'allow command with additional directory access (${request.command})?'
        : missing.length == 1 && missing.contains(ProcessPermission.network)
            ? 'allow network access for this command (${request.command})?'
            : resolution.route == AuthorizationRoute.allow && readOnlyProfile
                ? 'permitted read: enforced read-only execution'
                : resolution.reason;
    final reason = outsideSandbox
        ? 'Run this exact command outside the OS sandbox? '
            '${control!.sandboxReason}\n'
            'This grants host filesystem and network access to the command '
            'and its subprocesses. Other calls keep their configured confinement.'
        : network
            ? '$baseReason\nNetwork access: ${control?.networkReason ?? 'requested'}. '
                'Access applies to this subprocess and its children. '
                'Filesystem confinement is unchanged.'
            : baseReason;
    var remember = false;
    if (resolution.route != AuthorizationRoute.allow) {
      final review = CommandApproval(
        reason: reason,
        authorization: authorization,
        isActive: () =>
            !cancelled &&
            control?.isCancelled?.call() != true &&
            directoriesUnchanged(),
        requiredPermissions: requiredPermissions,
        missingPermissions: missing,
        directoryAccess: directoryAccess,
        networkReason: network ? control?.networkReason : null,
        sandboxReason: outsideSandbox ? control?.sandboxReason : null,
        readDirectory: candidate != null
            ? readDirectoryForRequest(readerRequest, workspaceRoot)
            : null,
      );
      final approve = commandApprover;
      final fileApprover = approver;
      // A filesystem-only approver cannot authorize network or remove the jail.
      if (approve == null &&
          (fileApprover == null ||
              missing.contains(ProcessPermission.network) ||
              missing.contains(ProcessPermission.directoryAccess) ||
              missing.contains(ProcessPermission.unconfined))) {
        return CommandRefused(
            '$reason — denied: no approver is wired to approve it');
      }
      final answer = approve != null
          ? approve(request, review)
          : fileApprover!(_asFileOperation(request), reason);
      final cancellation = control?.whenCancelled;
      final permission = await (cancellation == null
          ? answer
          : Future.any([answer, cancellation.then((_) => Approval.no)]));
      if (cancelled || control?.isCancelled?.call() == true) {
        return const CommandRefused('cancelled: command was not started');
      }
      if (permission == Approval.no) {
        return CommandRefused('$reason — denied by the user or cancelled');
      }
      if (permission == Approval.always) {
        remember = true;
      }
    }
    if (!directoriesUnchanged()) {
      return const CommandRefused(
          'Additional directories changed during approval');
    }
    final currentReaders =
        trustedReaderExecutables?.call() ?? const <String, String>{};
    final currentReader = readOnlyExecutable(readerRequest,
        searchPath: executableSearchPath, trustedExecutables: currentReaders);
    final currentShell = readOnlyShellRequest(request,
        searchPath: executableSearchPath,
        trustedExecutables: currentReaders,
        canWrite: outputWritePermission);
    if (reader != null && currentReader == null ||
        shellReader != null && currentShell == null)
      return const CommandRefused(
          'Reader executable or output permissions changed during approval');
    reader = currentReader;
    shellReader = currentShell;
    final onlyReads = !outsideSandbox && readOnlyProfile;
    const outputDirectories = <String>[];
    if (mode == PermissionMode.readOnly && !onlyReads) {
      return const CommandRefused(
          'Permission mode changed: workspace mutation is blocked.');
    }
    if (remember) {
      grants.rememberRequest(request,
          permissions: missing, directoryAccess: directoryAccess);
    }
    final authorized = (control ?? const ProcessControl()).copyWith(
        readOnly: onlyReads,
        outputDirectories: List.unmodifiable(outputDirectories),
        networkAllowed: network,
        outsideSandboxAllowed: outsideSandbox,
        approvedDirectories: directoryAccess,
        approvedHostEnvironment:
            outsideSandbox && plan != null ? request.environment : null);
    final spawned = reader == null
        ? shellReader ?? request
        : (
            command: reader,
            arguments: certifiedReaderArguments(readerRequest),
            workingDirectory: request.workingDirectory,
            environment: path.basename(reader) == 'git'
                ? {
                    ...?request.environment,
                    // Certified git readers must not refresh the index.
                    'GIT_OPTIONAL_LOCKS': '0',
                  }
                : request.environment,
            stdin: request.stdin,
            timeout: request.timeout,
          );
    bool active() => !cancelled && control?.isCancelled?.call() != true;
    final approveDirectory = directoryApprover;
    var outcome = await inner.run(spawned, control: authorized);
    if (confined &&
        !outsideSandbox &&
        approveDirectory != null &&
        outcome is CommandBlocked &&
        active()) {
      final candidates = outcome.accessRequests
          .where((candidate) =>
              plan?.canGrant(candidate.path, write: candidate.write) == true)
          .toList();
      if (candidates.length == 1 &&
          await approveDirectory(request, candidates.single, true, active) &&
          active()) {
        // Exactly one retry, explicitly authorized after possible partial work.
        final candidate = candidates.single;
        var directory = Directory(candidate.path).existsSync()
            ? candidate.path
            : path.dirname(candidate.path);
        while (!Directory(directory).existsSync()) {
          directory = path.dirname(directory);
        }
        if (mode == PermissionMode.readOnly &&
            (candidate.write || !authorized.readOnly)) {
          return const CommandRefused(
              'Read-only mode blocks write access and writable retries.');
        }
        final retryAccess = plan!.resolveDirectoryAccess(
            read: [...directoryAccess.read, if (!candidate.write) directory],
            write: [...directoryAccess.write, if (candidate.write) directory],
            cwd: request.workingDirectory ?? plan!.workspaceRoot,
            linux: _linux);
        outcome = await inner.run(spawned,
            control: authorized.copyWith(approvedDirectories: retryAccess));
      }
    }
    return _completed(outcome, reason);
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

  ProcessDirectoryAccess _directoryRequirements(
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
      if (commandWorkflow(request, plan.workspaceRoot) != null) {
        try {
          final executable = resolveHostExecutable(
              literalShellRequest(request) ?? request,
              workspace: plan.workspaceRoot,
              searchPath: executableSearchPath);
          var ancestor = Directory(path.dirname(executable));
          for (var depth = 0; depth < 5; depth++) {
            if (Directory(path.join(ancestor.path, 'packages', 'flutter_tools'))
                    .existsSync() &&
                Directory(path.join(ancestor.path, 'bin', 'cache'))
                    .existsSync()) {
              add(ancestor.path, false);
              add(path.join(ancestor.path, 'bin', 'cache'), true);
              break;
            }
            if (ancestor.parent.path == ancestor.path) break;
            ancestor = ancestor.parent;
          }
        } on FileSystemException {}
      }
      for (final access in verifiedReaderAccesses(request,
          searchPath: executableSearchPath,
          trustedExecutables: trustedReaderExecutables?.call() ?? const {})) {
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

  /// The approver is the filesystem's type: a [FileOperation]. The command's
  /// cwd — or the first path-like argument, when there is no cwd — is the
  /// path the ask dialog can show.
  static FileOperation _asFileOperation(ProcessRequest request) => (
        op: FileOp.write,
        path: request.workingDirectory ?? request.arguments.firstOrNull ?? '',
      );
}

// Inspection is quiet by default when the backend can enforce it. A command
// that needs mutations must request workspace-write (or additional write paths).
bool _defaultReadOnlyProfile(PermissionMode mode,
        {required bool confined,
        required bool certifiedReadOnly,
        bool writeRequested = false}) =>
    mode == PermissionMode.readOnly ||
    confined &&
        (certifiedReadOnly ||
            !writeRequested &&
                (mode == PermissionMode.ask || mode == PermissionMode.auto));

/// The command × mode table: the whole rule, as built. Pure — a request in,
/// a verdict out — so its tests are headless by construction.
///
/// Compatibility adapter for callers with a structured command. The same
/// resolver applies the mode ceiling before explicit grants.
CommandDecision decideCommand(
  ProcessRequest request,
  PermissionMode mode, {
  required WritableDirectories writableDirectories,
  required bool networkOff,
  CommandGrants? grants,
  bool certifiedReadOnly = false,
  bool confined = true,
  bool? readOnlyProfile,
}) {
  final readOnly = readOnlyProfile ??
      _defaultReadOnlyProfile(mode,
          confined: confined, certifiedReadOnly: certifiedReadOnly);
  final resolution = resolveAuthorization(
      AuthorizationRequest(
          readOnlyExecution: readOnly,
          confined: confined,
          requirements: [
            AccessRequirement(AccessCapability.execute, request.command,
                workspace: true,
                granted: grants?.coversRequest(request) == true ||
                    certifiedReadOnly && !readOnly),
            if (!readOnly)
              AccessRequirement(
                  AccessCapability.write, request.workingDirectory ?? '.',
                  workspace: true,
                  granted: grants?.coversRequest(request,
                          permission: ProcessPermission.workspaceWrite) ==
                      true),
          ]),
      mode);
  return (
    verdict: switch (resolution.route) {
      AuthorizationRoute.allow => ToolVerdict.allow,
      AuthorizationRoute.deny => ToolVerdict.deny,
      AuthorizationRoute.human || AuthorizationRoute.review => ToolVerdict.ask,
    },
    reason: resolution.route == AuthorizationRoute.allow && readOnly
        ? 'permitted read: enforced read-only execution'
        : resolution.reason
  );
}

/// The verdict plus the reason — same shape as `FileDecision`.
typedef CommandDecision = ({ToolVerdict verdict, String reason});

/// True when a request collapses a shell command into one argv element —
/// the `command: <shell>, arguments: ['-c', <string>]` shape every bash tool
/// produces. What the string runs cannot be proven from argv: redirects,
/// backticks, and newlines mean the writable directories can say nothing about it.
/// Shell syntax never grants access: the selected execution profile and the
/// shared permission policy determine which capabilities a script receives.
///
/// Shape test: the basename of [ProcessRequest.command] is a known shell and
/// the shell's flag is followed by a payload — i.e. there is at least one
/// argument that is not the flag itself. Flags carrying the string as their
/// value (`-c` on BSD, `-c` on Windows) are matched by name, not position,
/// so any arguments list containing `-c` with something after it counts.
bool argumentsCollapsed(ProcessRequest request) {
  final shell = request.command.split(Platform.pathSeparator).last;
  if (!_shells.contains(shell)) return false;
  // `-c <string>`: the payload argument exists whenever the args list holds
  // anything besides the flag tokens themselves.
  return request.arguments.any((a) => a != '-c' && a != '--command');
}

const _shells = {'sh', 'bash', 'dash', 'ash', 'zsh', 'ksh', 'bash5'};

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
