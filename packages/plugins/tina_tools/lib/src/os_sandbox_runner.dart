/// The OS-level sandbox as a [ProcessRunner] wrapper: the second layer of
/// enforcement, under the permission gate.
///
/// The gate ([SandboxedProcessRunner]) decides what is allowed by reading
/// arguments; it cannot stop what inspection cannot see — an interpreter,
/// a build tool that shells out, a command that reads tina's own
/// environment. This runner is the kernel's answer to that gap: the
/// command the gate approved runs inside a confinement built from the
/// **same** writable-directories configuration ([SandboxPlan]), so
/// approval and layout cannot disagree.
///
/// Layering (outermost last):
///
/// ```dart
/// OsSandboxRunner(inner: IoProcessRunner())   // the jail + the real spawn
/// SandboxedProcessRunner(inner: thatOne)      // our gate, outermost
/// ```
///
/// A request the gate approves but the OS denies surfaces as
/// [CommandBlocked] — never a bare non-zero exit, which the model would
/// read as an ordinary failure and retry in vain. When no confinement
/// exists on this host, the runner degrades exactly as the host chose
/// ([unavailableBehaviour]): pass the request through untouched, or
/// refuse outright. Never a silent jail-less run dressed as sandboxed.
library;

import 'dart:io';
import 'package:path/path.dart' as path;

import 'process_runner.dart';
import 'read_directories.dart';
import 'write_directories.dart';
import 'sandbox_failure.dart';
import 'sandbox_layout.dart';
import 'sandbox_home.dart';

/// Which OS-level confinement an [OsSandboxRunner] uses.
enum SandboxBackend {
  /// Linux: bubblewrap. Requires the binary and unprivileged user
  /// namespaces.
  bwrap,

  /// macOS: `sandbox-exec -p <profile>` (Seatbelt).
  sandboxExec,

  /// No confinement: requests pass to the inner runner untouched, or are
  /// refused — [OsSandboxRunner.unavailableBehaviour] decides. The
  /// permission gate above this layer still applies either way.
  passThrough,
}

/// Pure backend dispatch: the platform facts in, the backend out. The
/// convenience [resolveSandboxBackend] fills the facts from the running
/// host, so tests can drive every branch without being that host.
SandboxBackend resolveSandboxBackendFor({
  required bool isMacOS,
  required bool isLinux,
  required String osName,
  bool sandboxEnabled = true,
  bool sandboxExecPresent = false,
  bool bwrapPresent = false,
  bool userNsEnabled = true,
}) {
  if (!sandboxEnabled) return SandboxBackend.passThrough;
  if (isMacOS) {
    return sandboxExecPresent
        ? SandboxBackend.sandboxExec
        : SandboxBackend.passThrough;
  }
  if (isLinux) {
    return (bwrapPresent && userNsEnabled)
        ? SandboxBackend.bwrap
        : SandboxBackend.passThrough;
  }
  return SandboxBackend.passThrough; // windows & friends: no supported backend
}

/// [resolveSandboxBackendFor] against the running host.
SandboxBackend resolveSandboxBackend({
  bool sandboxEnabled = true,
  bool Function(String executable)? onPath,
}) =>
    resolveSandboxBackendFor(
      isMacOS: Platform.isMacOS,
      isLinux: Platform.isLinux,
      osName: Platform.operatingSystem,
      sandboxEnabled: sandboxEnabled,
      sandboxExecPresent: _present('/usr/bin/sandbox-exec', onPath),
      bwrapPresent: _present('bwrap', onPath),
      userNsEnabled: userNamespacesEnabled,
    );

/// Why the sandbox degraded to [SandboxBackend.passThrough] on a given
/// host — the reason a report or a warning names. Null when a backend is
/// active or the sandbox was turned off deliberately.
String? sandboxPassThroughReasonFor({
  required bool isMacOS,
  required bool isLinux,
  required String osName,
  bool sandboxEnabled = true,
  bool sandboxExecPresent = false,
  bool bwrapPresent = false,
  bool userNsEnabled = true,
}) {
  if (!sandboxEnabled) return null; // a deliberate disable is not a degradation
  if (isMacOS) {
    return sandboxExecPresent ? null : 'sandbox-exec not found';
  }
  if (isLinux) {
    if (!bwrapPresent) return 'bwrap not found on PATH';
    if (!userNsEnabled) return 'unprivileged user namespaces are disabled';
    return null;
  }
  return 'no supported sandbox backend for "$osName"';
}

/// Best-effort read of the kernel knobs bwrap depends on: false only when
/// a knob exists and is explicitly 0 (Debian's `unprivileged_userns_clone`,
/// `user.max_user_namespaces`). Knobs hidden by a container runtime count
/// as enabled — the bwrap invocation itself is the final word.
bool get userNamespacesEnabled {
  final clone = File('/proc/sys/kernel/unprivileged_userns_clone');
  if (clone.existsSync() && clone.readAsStringSync().trim() == '0') {
    return false;
  }
  final max = File('/proc/sys/user/max_user_namespaces');
  if (max.existsSync() && max.readAsStringSync().trim() == '0') return false;
  return true;
}

bool _present(String executable, bool Function(String)? probe) {
  if (probe != null) return probe(executable);
  if (executable.contains('/')) return File(executable).existsSync();
  for (final dir in (Platform.environment['PATH'] ?? '').split(':')) {
    if (dir.isEmpty) continue;
    if (File('$dir/$executable').existsSync()) return true;
  }
  return false;
}

/// What a host decides up front about running commands on a machine with
/// no OS sandbox (this container has neither binary). Not a permission
/// mode — there are two and they stay two — just the jail-less fallback:
///
/// - [allow] — the request runs **unsandboxed** through the inner runner,
///   exactly as it would have before this layer existed. Chosen when the
///   gate's approval is trusted to be enough on this machine.
/// - [refuse] — the command is refused outright: no jail, no run.
enum UnavailableBehaviour { allow, refuse }

/// The one configuration the writable directories and the OS layout are
/// built from — the brief's "one place": the gate approves exactly the
/// paths the kernel makes writable, never a hair less or more.
class SandboxPlan {
  static const defaultSearchPath = '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin';
  /// The session's project root: bound read-write in the namespace.
  final String workspaceRoot;

  /// Workspace Tina data. Its contents are hidden from subprocesses.
  final String? tinaDir;

  /// The writable directories the gate uses — the same list the layout
  /// binds read-write. Normally empty: the workspace is the writability.
  final List<String> writablePaths;

  final ReadOnlyDirectories? readDirectories;
  final WriteDirectories? writeDirectories;

  /// Network off unless the session says otherwise.
  final bool isolateNetwork;

  /// The child's environment, rebuilt from nothing (an explicit
  /// allowlist). The parent's environment — provider tokens among them —
  /// stops at this boundary: a plain `env` inside the jail prints only
  /// what is named here.
  final Map<String, String>? _childEnvironment;
  final Map<String, String>? parentEnvironment;
  final SandboxHome? home;
  final String? realHome;
  final List<String> protectedPaths;

  Map<String, String> get hostEnvironment =>
      parentEnvironment ?? Platform.environment;
  String? get hostHome => realHome ?? hostEnvironment['HOME'];
  String get searchPath =>
      _childEnvironment?['PATH'] ?? defaultSearchPath;
  Map<String, String> get childEnvironment =>
      _childEnvironment ??
      {
        'PATH': searchPath,
        'HOME': home?.ensure() ?? '/tmp',
        'TMPDIR': sandboxTempDirectory(hostEnvironment),
        'LANG': 'C.UTF-8',
      };
  Map<String, String> get outsideEnvironment => {
        'PATH': hostEnvironment['PATH'] ?? searchPath,
        'HOME': hostHome ?? '/tmp',
        'TMPDIR': sandboxTempDirectory(hostEnvironment),
        'LANG': hostEnvironment['LANG'] ?? 'C.UTF-8',
        if (hostEnvironment['SSH_AUTH_SOCK'] case final String socket)
          'SSH_AUTH_SOCK': socket,
      };
  List<String> get deniedPaths => sandboxPathAliases([
        ...protectedPaths,
        if (tinaDir != null) tinaDir!,
        if (hostHome case final String host)
          for (final relative in credentialHomePaths) path.join(host, relative),
      ]);
  bool isProtected(String value) {
    final targets = sandboxPathAliases([value]);
    return targets
        .any((target) => deniedPaths.any((root) => _under(target, root)));
  }

  bool canGrant(String value, {bool write = false, bool? linux}) {
    if (isProtected(value)) return false;
    if (write &&
        (linux ?? Platform.isLinux) &&
        writableLayout().any((root) =>
            _under(canonicalSandboxPath(value), canonicalSandboxPath(root))) &&
        !canWrite(value, linux: true)) return false;
    return true;
  }

  bool canWrite(String value, {bool? linux}) {
    if (isProtected(value)) return false;
    final target = canonicalSandboxPath(value);
    if (!writableLayout()
        .any((root) => _under(target, canonicalSandboxPath(root))))
      return false;
    if (linux ?? Platform.isLinux) {
      for (final parent in sandboxProtectedParents(
          deniedPaths, sandboxPathAliases(mountedLayout()))) {
        if (!_under(target, parent)) continue;
        final relative = path.relative(target, from: parent);
        if (relative == '.' ||
            !Directory(path.join(parent, path.split(relative).first))
                .existsSync()) return false;
      }
    }
    return true;
  }

  /// Match the actual backend's read policy, not Linux mount visibility on
  /// every platform. Protected aliases take precedence over all grants.
  bool canRead(String value, {SandboxBackend? backend}) {
    if (isProtected(value)) return false;
    final target = canonicalSandboxPath(value);
    final selected = backend ??
        (Platform.isMacOS ? SandboxBackend.sandboxExec : SandboxBackend.bwrap);
    if (selected == SandboxBackend.passThrough) return true;
    if (selected == SandboxBackend.sandboxExec) {
      final host = hostHome;
      if (host == null || !_under(target, canonicalSandboxPath(host)))
        return true;
      return sandboxPathAliases(readAllowPaths)
          .any((root) => _under(target, root));
    }
    return sandboxPathAliases([...mountedLayout(), '/dev', '/proc'])
        .any((root) => _under(target, root));
  }

  List<String> get readAllowPaths => [
        ...writableLayout(),
        ...?readDirectories?.existingPaths,
      ];

  ProcessDirectoryAccess resolveDirectoryAccess({
    Iterable<String> read = const [],
    Iterable<String> write = const [],
    required String cwd,
    bool? linux,
  }) {
    if (read.length + write.length > 32) {
      throw const FormatException(
          'At most 32 additional directories are allowed');
    }
    String resolve(String value, bool write) {
      if (value.trim().isEmpty || RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
        throw const FormatException('Invalid directory path');
      }
      final directory =
          Directory(path.isAbsolute(value) ? value : path.join(cwd, value));
      if (!directory.existsSync()) {
        throw const FormatException(
            'Additional access requires an existing directory; use its existing parent');
      }
      final resolved = directory.resolveSymbolicLinksSync();
      if (resolved == path.separator ||
          hostHome != null && resolved == canonicalSandboxPath(hostHome!) ||
          !canGrant(resolved, write: write, linux: linux)) {
        throw const FormatException(
            'Additional access must name a specific, unprotected directory');
      }
      return resolved;
    }

    return ProcessDirectoryAccess(
        read: read.map((value) => resolve(value, false)),
        write: write.map((value) => resolve(value, true)));
  }

  /// Revalidate after asynchronous approval and immediately before spawning.
  bool validDirectoryAccess(ProcessDirectoryAccess access, {bool? linux}) {
    try {
      final current = resolveDirectoryAccess(
          read: access.read,
          write: access.write,
          cwd: workspaceRoot,
          linux: linux);
      return current.read.join('\u0000') == access.read.join('\u0000') &&
          current.write.join('\u0000') == access.write.join('\u0000');
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    }
  }

  /// A private layout for one invocation. Never mutate live settings or the
  /// shared plan, which may be serving other running jobs.
  SandboxPlan withDirectoryAccess(ProcessDirectoryAccess access) {
    if (access.isEmpty) return this;
    return SandboxPlan(
      workspaceRoot: workspaceRoot,
      tinaDir: tinaDir,
      writablePaths: writablePaths,
      readDirectories: ReadOnlyDirectories()
        ..replace([...?readDirectories?.existingPaths, ...access.read]),
      writeDirectories: WriteDirectories()
        ..replace([...?writeDirectories?.existingPaths, ...access.write]),
      isolateNetwork: isolateNetwork,
      childEnvironment: _childEnvironment,
      parentEnvironment: parentEnvironment,
      home: home,
      realHome: realHome,
      protectedPaths: protectedPaths,
    );
  }

  /// The visible world: workspace, selected caches, session home and host
  /// temp directories; read-only toolchains and explicit grants. Credential
  /// and configuration exclusions take precedence over broader grants.
  const SandboxPlan({
    required this.workspaceRoot,
    this.tinaDir,
    this.writablePaths = const [],
    this.readDirectories,
    this.writeDirectories,
    this.isolateNetwork = true,
    Map<String, String>? childEnvironment,
    this.parentEnvironment,
    this.home,
    this.realHome,
    this.protectedPaths = const [],
  }) : _childEnvironment = childEnvironment;

  /// Every path the layout makes writable: the workspace root, the extra
  /// grants, and the temp scratch space. The gate's writable directories
  /// should be built from the same value.
  List<String> writableLayout() => [
        ...{
          workspaceRoot,
          ...extraWritablePaths,
          ...defaultSandboxTempDirs(hostEnvironment),
          if (home?.existingPath != null) home!.existingPath!,
          ...?home?.targets
        },
      ];

  List<String> get extraWritablePaths => [
        ...writablePaths,
        if (home?.existingPath != null) home!.existingPath!,
        ...?home?.targets,
        ...?writeDirectories?.existingPaths,
      ];

  /// Every path the layout mounts, writable or not — the classifier's
  /// notion of "inside the jail".
  List<String> mountedLayout() => [
        ...writableLayout(),
        ...kSandboxReadOnlyBinds,
        ...?readDirectories?.existingPaths,
        if (tinaDir != null) tinaDir!,
      ];
}

/// A [ProcessRunner] that runs each approved command inside an OS-level
/// confinement, then asks the failure classifier whether the kernel — not
/// the command — is why it failed.
final class OsSandboxRunner implements ProcessRunner {
  /// The runner beneath: the real spawn when the sandbox is active or the
  /// fallback lets the command through.
  final ProcessRunner inner;

  /// The one layout configuration (see [SandboxPlan]).
  final SandboxPlan plan;

  /// An explicit per-launch choice; independent of backend availability.
  final bool enabled;

  /// The backend resolved for this host. [SandboxBackend.passThrough]
  /// means the degradation path — see [unavailableBehaviour].
  final SandboxBackend backend;

  /// Why the backend degraded, or null. Named in the one-time warning.
  final String? passThroughReason;

  /// What happens to a command when no confinement exists: run it
  /// unsandboxed, or refuse it. The host states this; there is no third
  /// silent option.
  final UnavailableBehaviour unavailableBehaviour;

  /// Overrides the layout host probes; null inspects the real host.
  final SandboxHostLayout Function()? hostLayout;

  /// Optional observer for the one-time pass-through notice. The notice also
  /// goes through captured tool output and the completed command's stderr.
  final void Function(String message)? onWarn;

  bool _warned = false;

  OsSandboxRunner({
    required this.inner,
    required this.plan,
    this.enabled = true,
    SandboxBackend? backend,
    String? unavailableReason,
    this.unavailableBehaviour = UnavailableBehaviour.allow,
    this.hostLayout,
    this.onWarn,
  })  : backend = backend ??
            (enabled ? resolveSandboxBackend() : SandboxBackend.passThrough),
        passThroughReason = enabled
            ? _reason(backend ?? resolveSandboxBackend(), unavailableReason)
            : null;

  static String? _reason(SandboxBackend backend, String? override) {
    if (backend != SandboxBackend.passThrough) return null;
    return override ??
        sandboxPassThroughReasonFor(
          isMacOS: Platform.isMacOS,
          isLinux: Platform.isLinux,
          osName: Platform.operatingSystem,
          sandboxExecPresent: _present('/usr/bin/sandbox-exec', null),
          bwrapPresent: _present('bwrap', null),
          userNsEnabled: userNamespacesEnabled,
        );
  }

  @override
  Future<RunOutcome> run(ProcessRequest request,
      {ProcessControl? control}) async {
    final access =
        control?.approvedDirectories ?? const ProcessDirectoryAccess.empty();
    if ((control?.readDirectories.isNotEmpty == true ||
            control?.writeDirectories.isNotEmpty == true) &&
        control?.approvedDirectories == null) {
      return const CommandRefused('Directory access has not been approved.');
    }
    if (!this
        .plan
        .validDirectoryAccess(access, linux: backend == SandboxBackend.bwrap)) {
      return const CommandRefused(
          'Approved directories changed before execution');
    }
    final plan = this.plan.withDirectoryAccess(access);
    if (control?.outsideSandboxRequested == true &&
        (control?.outsideSandboxAllowed != true ||
            control?.networkAllowed != true)) {
      return const CommandRefused(
          'Outside-sandbox execution requires explicit approval for host '
          'filesystem and network access.');
    }
    if (!enabled || control?.outsideSandboxRequested == true) {
      // Keep provider credentials out of the process environment even when
      // this exact invocation is explicitly allowed to run without a jail.
      return inner.run((
        command: request.command,
        arguments: request.arguments,
        workingDirectory: request.workingDirectory,
        environment: control?.outsideSandboxRequested == true &&
                control?.approvedHostEnvironment != null
            ? {
                // The gate snapshots these fields before human approval.
                // Never inherit arbitrary environment variables here.
                for (final key in [
                  'PATH',
                  'HOME',
                  'TMPDIR',
                  'LANG',
                  'SSH_AUTH_SOCK'
                ])
                  if (control!.approvedHostEnvironment!.containsKey(key))
                    key: control.approvedHostEnvironment![key]!,
              }
            : plan.outsideEnvironment,
        stdin: request.stdin,
        timeout: request.timeout,
      ), control: control);
    }
    if (backend == SandboxBackend.passThrough) {
      final warning = _warnOnce();
      if (warning != null) {
        try {
          control?.onOutput?.call('$warning\n', isError: true);
        } catch (_) {
          // Output observers cannot change the command's outcome.
        }
      }
      final outcome = switch (unavailableBehaviour) {
        UnavailableBehaviour.allow => await inner.run((
            command: request.command,
            arguments: request.arguments,
            workingDirectory: request.workingDirectory,
            environment: plan.outsideEnvironment,
            stdin: request.stdin,
            timeout: request.timeout
          ), control: control),
        UnavailableBehaviour.refuse =>
          CommandRefused('the OS sandbox is unavailable on this host '
              '(${passThroughReason ?? 'no backend'}); this command was not '
              'allowed to run unsandboxed'),
      };
      // Keep the warning in the result as well as the live output. It must
      // survive a collapsed tool call or a background job without writing
      // directly to the terminal owned by the frontend.
      if (warning != null && outcome is CommandCompleted) {
        return CommandCompleted(
          exitCode: outcome.exitCode,
          stdout: outcome.stdout,
          stderr: '$warning\n${outcome.stderr}',
          note: outcome.note,
          cancelled: outcome.cancelled,
          timedOut: outcome.timedOut,
        );
      }
      return outcome;
    }
    try {
      final data = plan.tinaDir;
      if (backend == SandboxBackend.bwrap &&
          data != null &&
          _under(data, plan.workspaceRoot) &&
          Directory(plan.workspaceRoot).existsSync()) {
        Directory(data).createSync(recursive: true);
      }
      plan.home?.ensure();
      // Resolve every protected alias before spawning; broken links fail closed.
      plan.deniedPaths;
    } on FileSystemException catch (error) {
      return CommandRefused('Cannot prepare protected sandbox paths: $error');
    }
    final layout = _layout(plan);
    final mounted = _mountedPaths(layout, plan);
    if (backend == SandboxBackend.bwrap && path.isAbsolute(request.command)) {
      final file = File(request.command);
      // Bind sources can be symlinks. Their resolved host paths need not be
      // mounted by name: contents are exposed at the bind destination. Only
      // diagnose names definitely absent from the subprocess namespace.
      if (file.existsSync() &&
          !mounted.any((m) => _under(request.command, m))) {
        return CommandBlocked(
            PathHidden([request.command]).recoveryInstructions,
            accessRequests: [
              SandboxAccessRequest(request.command, write: false)
            ]);
      }
    }
    // The jailed argv wraps the requested command; the request keeps its
    // own program and arguments verbatim after the jail's own.
    final (String jail, List<String> jailArgs) = switch (backend) {
      SandboxBackend.bwrap => (
          'bwrap',
          buildBwrapArguments(
            host: layout,
            workspaceRoot: plan.workspaceRoot,
            deniedPaths: plan.deniedPaths,
            writablePaths: control?.readOnly == true
                ? control!.outputDirectories
                : plan.extraWritablePaths,
            readOnlyPaths:
                control?.readOnly == true ? plan.extraWritablePaths : const [],
            readOnlyWorkspace: control?.readOnly == true,
            isolateNetwork:
                plan.isolateNetwork && !(control?.networkAllowed ?? false),
            childEnvironment: plan.childEnvironment,
          ),
        ),
      SandboxBackend.sandboxExec => (
          'sandbox-exec',
          [
            '-p',
            buildSeatbeltProfile(
              writablePaths: control?.readOnly == true
                  ? defaultSandboxTempDirs(plan.hostEnvironment)
                  : plan.writableLayout(),
              readOnlyPaths: control?.readOnly == true
                  ? [plan.workspaceRoot, ...plan.extraWritablePaths]
                  : const [],
              outputDirectories: control?.readOnly == true
                  ? control!.outputDirectories
                  : const [],
              deniedPaths: plan.deniedPaths,
              hidePath: plan.hostHome == null
                  ? null
                  : canonicalSandboxPath(plan.hostHome!),
              readAllowPaths: sandboxPathAliases(plan.readAllowPaths),
              isolateNetwork:
                  plan.isolateNetwork && !(control?.networkAllowed ?? false),
            ),
          ],
        ),
      SandboxBackend.passThrough => ('', const []),
    };
    final completed = await inner.run((
      command: jail,
      arguments: [...jailArgs, request.command, ...request.arguments],
      workingDirectory: request.workingDirectory,
      environment: plan.childEnvironment,
      stdin: request.stdin,
      timeout: request.timeout,
    ), control: control);
    return completed is CommandCompleted
        ? _decode(completed, mounted, request, plan)
        : completed;
  }

  /// Translate the confined run's outcome: a zero exit is a normal
  /// completion; a failure the classifier blames on the kernel becomes
  /// [CommandBlocked]; anything else stays an ordinary completed run.
  RunOutcome _decode(CommandCompleted completed, List<String> mounted,
      ProcessRequest request, SandboxPlan plan) {
    if (completed.exitCode == 0 || completed.cancelled || completed.timedOut)
      return completed;
    final denial = classifySandboxFailure(
      completed,
      writablePaths: plan.writableLayout(),
      deniedPaths: plan.deniedPaths,
      canWrite: (value) =>
          plan.canWrite(value, linux: backend == SandboxBackend.bwrap),
      accessIsWrite: {'touch', 'mkdir'}.contains(path.basename(request.command))
          ? true
          : {'cat', 'head', 'tail', 'ls', 'stat', 'grep'}
                  .contains(path.basename(request.command))
              ? false
              : null,
      mountedPaths: mounted,
      hostFileExists:
          backend == SandboxBackend.bwrap ? (p) => File(p).existsSync() : null,
    );
    if (denial == null) return completed;
    return CommandBlocked(denial.recoveryInstructions, accessRequests: [
      if (denial is WriteDenied)
        for (final value in denial.blockedPaths)
          if (plan.canGrant(value,
              write: true, linux: backend == SandboxBackend.bwrap))
            SandboxAccessRequest(value, write: true),
      if (denial is OperationDenied && denial.write != null)
        for (final value in denial.paths)
          if (plan.canGrant(value,
              write: denial.write!, linux: backend == SandboxBackend.bwrap))
            SandboxAccessRequest(value, write: denial.write!),
      if (denial is PathHidden)
        for (final value in denial.hiddenPaths)
          if (plan.canGrant(value)) SandboxAccessRequest(value, write: false),
    ]);
  }

  List<String> _mountedPaths(SandboxHostLayout layout, SandboxPlan plan) => [
        ...layout.readOnlyDirectories,
        ...layout.temporaryDirectories,
        plan.workspaceRoot,
        ...plan.extraWritablePaths,
        if (layout.resolverTarget != null) layout.resolverTarget!,
        '/dev',
        '/proc',
      ];

  SandboxHostLayout _layout([SandboxPlan? invocation]) {
    final plan = invocation ?? this.plan;
    final base = hostLayout?.call() ??
        SandboxHostLayout.inspect(
          readOnlyDirectories: kSandboxReadOnlyBinds,
          temporaryDirectories: defaultSandboxTempDirs(plan.hostEnvironment),
        );
    return SandboxHostLayout(
      readOnlyDirectories: {
        ...base.readOnlyDirectories,
        ...?plan.readDirectories?.existingPaths.where((read) =>
            !plan.extraWritablePaths.any((write) => _under(read, write))),
      },
      temporaryDirectories: base.temporaryDirectories,
      resolverTarget: base.resolverTarget,
    );
  }

  /// Describe the same backend and layout the runner actually uses.
  String describeEnvironment() {
    if (!enabled) {
      return 'OS sandbox deliberately disabled for this run (--no-sandbox). '
          'Commands have host filesystem and network access; network: false '
          'cannot isolate them. Permission modes and approval checks still '
          'apply. Child environments remain filtered.';
    }
    if (backend == SandboxBackend.passThrough) {
      return 'OS sandbox unavailable (${passThroughReason ?? 'no backend'}): '
          '${unavailableBehaviour == UnavailableBehaviour.allow ? 'approved commands run without OS confinement' : 'commands are refused'}. '
          'The permission gate still applies.';
    }
    final network = plan.isolateNetwork
        ? 'Network is isolated unless network access is approved.'
        : 'Network isolation is disabled.';
    if (backend == SandboxBackend.sandboxExec) {
      return 'OS sandbox: sandbox-exec (macOS). Real-home reads are restricted '
          'to the workspace, shared caches and explicit grants. Writes: '
          '${plan.writableLayout().join(', ')}. ${_homeDescription()} $network';
    }
    final layout = _layout();
    final readOnly = [
      ...layout.readOnlyDirectories,
      if (layout.resolverTarget != null) layout.resolverTarget!,
    ];
    final writable = {
      plan.workspaceRoot,
      ...plan.extraWritablePaths,
      ...layout.temporaryDirectories
    };
    return 'OS sandbox: bwrap (Linux). Subprocess read-only mounts: '
        '${readOnly.join(', ')}. Subprocess writable mounts: ${writable.join(', ')}. '
        '/dev and /proc are provided by the sandbox. Host paths not listed '
        'here are hidden. ${_homeDescription()} /home, /mnt and /media are only accessible where '
        'covered by a listed mount. $network '
        'Built-in file tools inspect the host filesystem under their own '
        'permission policy. A successful stat/read does not prove exec or '
        'bash can access that path. Both process tools use the same sandbox.';
  }

  String _homeDescription() =>
      'HOME: ${plan.home?.existingPath ?? (plan.home != null ? "session home created at first command" : plan.childEnvironment['HOME'])}. '
      'TMPDIR: ${sandboxTempDirectory(plan.hostEnvironment)}. '
      'Shared writable cache targets: ${plan.home?.targets.join(', ') ?? "none"}. '
      'Protected credential/config paths remain excluded even beneath grants: '
      '${plan.deniedPaths.join(', ')}.';

  String? _warnOnce() {
    if (_warned) return null;
    _warned = true;
    final runs = switch (unavailableBehaviour) {
      UnavailableBehaviour.allow => 'commands run unsandboxed',
      UnavailableBehaviour.refuse => 'commands are refused at this layer',
    };
    final warning =
        'OS sandbox unavailable (${passThroughReason ?? 'no backend'}): '
        '$runs. The permission gate still applies.';
    onWarn?.call(warning);
    return warning;
  }
}

bool _under(String child, String parent) {
  final c = path.normalize(child);
  final p = path.normalize(parent);
  return path.equals(c, p) || path.isWithin(p, c);
}
