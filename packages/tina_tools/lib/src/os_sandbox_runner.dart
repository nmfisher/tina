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

import 'process_runner.dart';
import 'sandbox_failure.dart';
import 'sandbox_layout.dart';

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
  /// The session's project root: bound read-write in the namespace.
  final String workspaceRoot;

  /// tina's own data directory: visible **read-only** so version queries
  /// work, not writable by sandboxed commands.
  final String? tinaDir;

  /// The writable directories the gate uses — the same list the layout
  /// binds read-write. Normally empty: the workspace is the writability.
  final List<String> writablePaths;

  /// Network off unless the session says otherwise.
  final bool isolateNetwork;

  /// The child's environment, rebuilt from nothing (an explicit
  /// allowlist). The parent's environment — provider tokens among them —
  /// stops at this boundary: a plain `env` inside the jail prints only
  /// what is named here.
  final Map<String, String> childEnvironment;

  /// The visible world: the project read-write, tina's data read-only,
  /// the toolchain directories read-only ([kSandboxReadOnlyBinds]), a
  /// scratch /tmp. Not visible: `$HOME`, credentials, the rest of the
  /// host.
  const SandboxPlan({
    required this.workspaceRoot,
    this.tinaDir,
    this.writablePaths = const [],
    this.isolateNetwork = true,
    this.childEnvironment = const {
      'PATH': '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
      'HOME': '/tmp',
      'TMPDIR': '/tmp',
      'LANG': 'C.UTF-8',
    },
  });

  /// Every path the layout makes writable: the workspace root, the extra
  /// grants, and the temp scratch space. The gate's writable directories
  /// should be built from the same value.
  List<String> writableLayout() => [
        ...{workspaceRoot, ...writablePaths, ...defaultSandboxTempDirs()},
      ];

  /// Every path the layout mounts, writable or not — the classifier's
  /// notion of "inside the jail".
  List<String> mountedLayout() => [
        ...writableLayout(),
        ...kSandboxReadOnlyBinds,
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

  /// Warn sink for the one-time pass-through notice; null is silent.
  final void Function(String message)? onWarn;

  bool _warned = false;

  OsSandboxRunner({
    required this.inner,
    required this.plan,
    SandboxBackend? backend,
    String? unavailableReason,
    this.unavailableBehaviour = UnavailableBehaviour.allow,
    this.hostLayout,
    this.onWarn,
  })  : backend = backend ?? resolveSandboxBackend(),
        passThroughReason =
            _reason(backend ?? resolveSandboxBackend(), unavailableReason);

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
  Future<RunOutcome> run(ProcessRequest request) async {
    if (backend == SandboxBackend.passThrough) {
      _warnOnce();
      return switch (unavailableBehaviour) {
        UnavailableBehaviour.allow => inner.run(request),
        UnavailableBehaviour.refuse => CommandRefused(
            'the OS sandbox is unavailable on this host '
            '(${passThroughReason ?? 'no backend'}); this command was not '
            'allowed to run unsandboxed'),
      };
    }
    final layout = hostLayout?.call() ??
        SandboxHostLayout.inspect(
          readOnlyDirectories: kSandboxReadOnlyBinds,
          temporaryDirectories: defaultSandboxTempDirs(),
        );
    // The jailed argv wraps the requested command; the request keeps its
    // own program and arguments verbatim after the jail's own.
    final (String jail, List<String> jailArgs) = switch (backend) {
      SandboxBackend.bwrap => (
          'bwrap',
          buildBwrapArguments(
            host: layout,
            workspaceRoot: plan.workspaceRoot,
            tinaDir: plan.tinaDir,
            writablePaths: plan.writablePaths,
            isolateNetwork: plan.isolateNetwork,
            childEnvironment: plan.childEnvironment,
          ),
        ),
      SandboxBackend.sandboxExec => (
          'sandbox-exec',
          [
            '-p',
            buildSeatbeltProfile(
              writablePaths: plan.writableLayout(),
              isolateNetwork: plan.isolateNetwork,
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
    )) as CommandCompleted;
    return _decode(completed);
  }

  /// Translate the confined run's outcome: a zero exit is a normal
  /// completion; a failure the classifier blames on the kernel becomes
  /// [CommandBlocked]; anything else stays an ordinary completed run.
  RunOutcome _decode(CommandCompleted completed) {
    if (completed.exitCode == 0) return completed;
    final denial = classifySandboxFailure(
      completed,
      writablePaths: plan.writableLayout(),
      mountedPaths: plan.mountedLayout(),
    );
    if (denial == null) return completed;
    return CommandBlocked(denial.recoveryInstructions);
  }

  void _warnOnce() {
    if (_warned) return;
    _warned = true;
    final runs = switch (unavailableBehaviour) {
      UnavailableBehaviour.allow => 'commands run unsandboxed',
      UnavailableBehaviour.refuse => 'commands are refused at this layer',
    };
    onWarn?.call(
        'OS sandbox unavailable (${passThroughReason ?? 'no backend'}): '
        '$runs. The permission gate still applies.');
  }
}
