import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../permissions/sandbox_access.dart';
import 'process_runner.dart';
import 'sandbox_layout.dart';

final _log = Logger('tina.sandbox');

/// True when macOS `sandbox-exec` is available to confine subprocess writes.
/// One of the probes [resolveSandboxBackend] consults; kept as a getter so
/// tests on macOS exercise the real path.
bool get sandboxExecAvailable =>
    Platform.isMacOS && File('/usr/bin/sandbox-exec').existsSync();

/// Canonical system directories the Linux sandbox mounts read-only: visible
/// inside the namespace so toolchains/compilers keep working, but not
/// writable. Each is bound only when it exists on the host (bwrap fails on a
/// missing source).
///
/// `/home`, `/mnt`, `/media`, `/srv` and `/var` are mounted READ-ONLY so
/// files outside the project actually EXIST inside the namespace — venvs and
/// toolchains under `$HOME`, datasets on mounted volumes, logs under `/var`.
/// Without these binds a command like `cat /home/me/data.csv` failed with
/// "No such file or directory" for a file that plainly exists (bwrap is
/// namespace-first: unmounted means invisible). Writes outside the project
/// still fail — read-only is exactly the point; `TINA_SANDBOX_ALLOW` remains
/// the escape hatch for a writable grant (see docs/features/sandbox.md).
const List<String> kLinuxSandboxReadOnlyBinds = <String>[
  '/usr',
  '/bin',
  '/sbin',
  '/lib',
  '/lib64',
  '/etc',
  '/opt',
  '/home',
  '/mnt',
  '/media',
  '/srv',
  '/var',
];

/// True when the `bwrap` binary is on PATH.
bool get bwrapOnPath => _findOnPath('bwrap') != null;

/// Best-effort read of the kernel knobs bwrap depends on: false only when a
/// knob exists and is explicitly 0 (Debian's `unprivileged_userns_clone`,
/// `user.max_user_namespaces`). Knobs hidden by a container runtime count as
/// enabled — the bwrap invocation itself is the final word.
bool get userNamespacesEnabled {
  final clone = File('/proc/sys/kernel/unprivileged_userns_clone');
  if (clone.existsSync() && clone.readAsStringSync().trim() == '0') {
    return false;
  }
  final max = File('/proc/sys/user/max_user_namespaces');
  if (max.existsSync() && max.readAsStringSync().trim() == '0') return false;
  return true;
}

/// True when Linux `bwrap` can actually confine: binary present AND
/// unprivileged user namespaces enabled.
bool get bwrapAvailable =>
    Platform.isLinux && bwrapOnPath && userNamespacesEnabled;

String? _findOnPath(String name) {
  for (final dir
      in Platform.environment['PATH']?.split(':') ?? const <String>[]) {
    if (dir.isEmpty) continue;
    final candidate = p.join(dir, name);
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

/// Which OS-level confinement backend a [SandboxedProcessRunner] wraps
/// commands with.
enum SandboxBackend {
  /// macOS Seatbelt: `sandbox-exec -p <profile>`.
  sandboxExec,

  /// Linux user namespaces: `bwrap <mounts> --`.
  bwrap,

  /// No OS-level confinement: bash runs unsandboxed (the denylist +
  /// permission gate still apply).
  passThrough,
}

/// Resolve the backend for a platform + binary availability, independent of
/// the current machine so every branch is unit-testable.
/// [resolveSandboxBackend] is the convenience that fills the probes from this
/// host.
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
    return bwrapPresent && userNsEnabled
        ? SandboxBackend.bwrap
        : SandboxBackend.passThrough;
  }
  return SandboxBackend.passThrough; // windows & friends: no supported backend
}

/// [resolveSandboxBackendFor] against the running host.
SandboxBackend resolveSandboxBackend({bool sandboxEnabled = true}) =>
    resolveSandboxBackendFor(
      isMacOS: Platform.isMacOS,
      isLinux: Platform.isLinux,
      osName: Platform.operatingSystem,
      sandboxEnabled: sandboxEnabled,
      sandboxExecPresent: sandboxExecAvailable,
      bwrapPresent: bwrapOnPath,
      userNsEnabled: userNamespacesEnabled,
    );

/// Why bash runs unsandboxed when the sandbox is explicitly turned off.
/// Two wordings exist: the explicit `--no-sandbox` flag, and `--yolo` (which
/// disables the sandbox unless `--sandbox` re-asserts it). The chip, the
/// startup notice, and the capabilities log all render one of these.
const String kSandboxOffReasonNoSandbox = 'explicitly disabled (--no-sandbox)';
const String kSandboxOffReasonYolo =
    'disabled by --yolo (pass --sandbox to keep it)';

/// Why the sandbox degrades to [SandboxBackend.passThrough] on a given host,
/// or null when a real backend is active. Same shape as
/// [resolveSandboxBackendFor] so tests can drive every branch.
///
/// When [sandboxEnabled] is false, [explicitOffReason] says who turned it
/// off (see [kSandboxOffReasonNoSandbox] / [kSandboxOffReasonYolo]); host
/// capability reasons (missing bwrap, disabled user namespaces) only apply
/// when the sandbox was wanted.
String? sandboxPassThroughReasonFor({
  required bool isMacOS,
  required bool isLinux,
  required String osName,
  bool sandboxEnabled = true,
  String explicitOffReason = kSandboxOffReasonNoSandbox,
  bool sandboxExecPresent = false,
  bool bwrapPresent = false,
  bool userNsEnabled = true,
}) {
  if (!sandboxEnabled) return explicitOffReason;
  if (isMacOS) {
    return sandboxExecPresent ? null : 'sandbox-exec not found';
  }
  if (isLinux) {
    if (!bwrapPresent) return 'bwrap not found on PATH';
    if (!userNsEnabled) return 'unprivileged user namespaces are disabled';
    return null;
  }
  return 'no sandbox backend for "$osName"';
}

/// [sandboxPassThroughReasonFor] against the running host.
String? get sandboxPassThroughReason => sandboxPassThroughReasonFor(
      isMacOS: Platform.isMacOS,
      isLinux: Platform.isLinux,
      osName: Platform.operatingSystem,
      sandboxExecPresent: sandboxExecAvailable,
      bwrapPresent: bwrapOnPath,
      userNsEnabled: userNamespacesEnabled,
    );

/// One-line diagnostic naming the active backend (and the degradation reason
/// when pass-through) for the startup log.
String describeSandboxBackend(SandboxBackend backend,
    {String? passThroughReason}) {
  return switch (backend) {
    SandboxBackend.sandboxExec =>
      'sandbox-exec (macOS): bash writes confined to the project root + '
          'temp; reads/network stay open',
    SandboxBackend.bwrap =>
      'bwrap (Linux): bash confined to read-only system dirs (home, mounts, '
          'var included) + writable project/temp; writes outside the project '
          'fail',
    SandboxBackend.passThrough =>
      'pass-through ($passThroughReason): bash runs unsandboxed — the '
          'denylist + permission gate still apply',
  };
}

/// Build a `sandbox-exec -p` profile that confines file *writes* to the project
/// root, the OS temp tree, a couple of pseudo-devices, and any [extraAllowPaths]
/// — while leaving reads, network, and process spawning unrestricted. This is
/// the structural guard against a runaway `rm`/`find -delete`/etc. reaching
/// outside the project: unlike the denylist (a regex on raw shell) it can't be
/// routed around with `python3 -c` or `base64 -d | sh`.
///
/// With [sandboxReadOnly] (opt-in `--sandbox-readonly`) the project's writable
/// grant is dropped and reads under `/Users` are denied, with the project
/// re-granted read-only — a pure read/analyze run. Reads outside `$HOME` stay
/// open: the macOS profile keeps `(allow default)` as its baseline (the
/// stronger namespace-first default lives on Linux; see
/// docs/features/sandbox.md).
///
/// Paths are resolved to their real form first so `/tmp`→`/private/tmp` and
/// symlinked roots are matched correctly by sandbox-exec's `(subpath …)`. A
/// path that can't be resolved is skipped (with a log) rather than embedded
/// verbatim — a bad allow-path must never silently widen or break the profile.
String buildSandboxProfile({
  required String projectRoot,
  List<String> extraAllowPaths = const [],
  bool sandboxReadOnly = false,
  bool sandboxNet = false,
  String? homeOverride,
}) {
  final allow = <String>{};
  // The project root is the one path the agent must be able to write to —
  // unless the run is declared read-only, when it gets a read grant below.
  final root = _resolve(projectRoot);
  if (!sandboxReadOnly && root != null) allow.add(root);
  // macOS per-user temp + caches (`$TMPDIR` lives under /private/var/folders).
  allow.addAll(['/private/var/folders', '/private/tmp', '/tmp']);
  // Pseudo-devices a normal command writes to.
  allow.addAll(['/dev/null', '/dev/dtracehelper']);
  for (final e in extraAllowPaths) {
    final r = _resolve(e);
    if (r != null) {
      allow.add(r);
    } else {
      _log.warning('sandbox: ignoring unresolvable allow-path "$e"');
    }
  }

  // A read-only run hides the user's home from reads. Resolve the real home so
  // a non-standard `$HOME` is covered; `/Users` is only the fallback when HOME
  // is unusable.
  final homeEnv = homeOverride ?? Platform.environment['HOME'];
  final home =
      (homeEnv == null || homeEnv.isEmpty) ? null : _resolve(homeEnv);
  if (sandboxReadOnly && home == null) {
    _log.warning('sandbox: cannot resolve \$HOME; hiding /Users from reads');
  }
  return buildMacSandboxProfile(
      writablePaths: allow,
      root: root,
      readOnlyProject: sandboxReadOnly,
      readDenyPaths: sandboxReadOnly ? [home ?? '/Users'] : const [],
      isolateNetwork: sandboxNet);
}

/// Build the `bwrap` argument list that gives Linux parity with the macOS
/// write-confinement: system directories mounted read-only, the project root +
/// temp trees writable, pseudo-devices provided, network on. `$HOME` and the
/// rest of the filesystem are simply not mounted — bwrap is namespace-first,
/// so unmounted means invisible (a deliberately stronger default than macOS,
/// where reads stay open; see docs/features/sandbox.md).
///
/// Pure over its inputs modulo the same host probes [buildSandboxProfile]
/// makes (path resolution + existence checks), so it is unit-testable without
/// bwrap. Bind order matters: mounts are applied in argv order, so temp before
/// project lets a read-only project bind shadow a writable temp parent, and an
/// [extraAllowPaths] grant inside the project stays writable even under
/// [sandboxReadOnly].
List<String> buildBwrapArgs({
  required String projectRoot,
  List<String>? tempDirs,
  List<String> extraAllowPaths = const [],
  List<String> readOnlyBinds = kLinuxSandboxReadOnlyBinds,
  bool sandboxNet = false,
  bool sandboxReadOnly = false,
}) {
  final temps = <String>{
    for (final path in tempDirs ?? _defaultBwrapTempDirs())
      if (_resolve(path) case final String resolved) resolved,
  };
  return buildLinuxSandboxArguments(
    host: SandboxHostLayout.inspect(readOnlyDirectories: readOnlyBinds,
        temporaryDirectories: temps),
    projectRoot: _resolve(projectRoot),
    writablePaths: [for (final path in extraAllowPaths)
      if (_resolve(path) case final String resolved) resolved],
    readOnlyProject: sandboxReadOnly,
    isolateNetwork: sandboxNet,
  );
}

List<String> _defaultBwrapTempDirs([Map<String, String>? environment]) {
  final tmp = (environment ?? Platform.environment)['TMPDIR'];
  return [if (tmp != null && tmp.isNotEmpty) tmp, '/tmp', '/var/tmp'];
}

String? _resolve(String path) {
  try {
    return Directory(path).resolveSymbolicLinksSync();
  } catch (_) {
    // Non-existent or unreadable — fall back to a normalized absolute form so a
    // still-useful path isn't dropped entirely.
    final abs = p.normalize(p.isAbsolute(path) ? path : p.absolute(path));
    return File(abs).parent.existsSync() ? abs : null;
  }
}


/// A [ProcessRunner] decorator that runs every command under an OS-level write
/// confinement: `sandbox-exec` on macOS, `bwrap` on Linux (see
/// [buildSandboxProfile] / [buildBwrapArgs]). On platforms with no backend —
/// or when the binary is missing / user namespaces are disabled — it degrades
/// to a transparent pass-through with a one-time warning naming the reason.
///
/// Wrapping at this seam means [BashTool]'s existing cancel/timeout/kill logic
/// (which operates on the returned process's pid + descendant tree) is
/// unchanged, and tests that inject a fake [ProcessRunner] directly into
/// [BashTool] bypass the sandbox entirely.
class SandboxedProcessRunner implements ProcessRunner {
  final ProcessRunner _inner;

  /// Host-only escape hatch for a separately approved, single invocation.
  /// Does not alter this runner or its session directory grants.
  ProcessRunner get outsideSandbox => _inner;
  final Map<String, String> environment;
  bool get networkIsolated => _sandboxNet && _backend != SandboxBackend.passThrough;
  final String _projectRoot;
  final SandboxAccessPolicy accessPolicy;
  final bool _enabled;
  final bool _sandboxNet;
  final bool _sandboxReadOnly;

  /// The resolved backend; [SandboxBackend.passThrough] means pass-through.
  /// Injectable so argv-rewrite tests are platform-independent.
  final SandboxBackend _backend;
  final String? _passThroughReason;
  final void Function(String message) _warn;

  bool _warnedAboutUnavailable = false;

  SandboxedProcessRunner({
    ProcessRunner? inner,
    Map<String, String>? environment,
    required String projectRoot,
    List<String> extraAllowPaths = const [],
    SandboxAccessPolicy? accessPolicy,
    bool? enabled, // false = deliberate disable (--no-sandbox / tests)
    bool sandboxNet = false,
    bool sandboxReadOnly = false,
    SandboxBackend?
        backend, // test override; defaults to [resolveSandboxBackend]
    String?
        unavailableReason, // test override; defaults to [sandboxPassThroughReason]
    void Function(String message)? warn, // test sink; defaults to the logger
  })  : environment = Map.unmodifiable(environment ?? Platform.environment),
        _inner = inner ?? const IoProcessRunner(),
        _projectRoot = projectRoot,
        accessPolicy = accessPolicy ??
            SandboxAccessPolicy(
              writablePaths: extraAllowPaths,
              readOnlyPaths: [if (sandboxReadOnly) projectRoot],
              implicitWritablePaths: [
                if (!sandboxReadOnly) projectRoot,
                if ((backend ?? resolveSandboxBackend()) ==
                    SandboxBackend.sandboxExec) ...[
                  '/private/var/folders',
                  '/private/tmp',
                  '/tmp'
                ] else
                  ..._defaultBwrapTempDirs(environment),
              ],
            ),
        _enabled = enabled ?? true,
        _sandboxNet = sandboxNet,
        _sandboxReadOnly = sandboxReadOnly,
        _backend =
            backend ?? resolveSandboxBackend(sandboxEnabled: enabled ?? true),
        _passThroughReason = unavailableReason,
        _warn = warn ?? _log.warning;

  /// Snapshot the approved access for one invocation. Never change the shared
  /// runner for an allow-once answer: other agents may be executing it.
  SandboxedProcessRunner withApprovedAccess(SandboxAccessRequest request,
      {required bool remember}) {
    final invocationPolicy = accessPolicy.forInvocation(request);
    if (remember) accessPolicy.grantForSession(request);
    return SandboxedProcessRunner(
      inner: _inner,
      environment: environment,
      projectRoot: _projectRoot,
      accessPolicy: invocationPolicy,
      enabled: _enabled,
      sandboxNet: _sandboxNet,
      sandboxReadOnly: _sandboxReadOnly,
      backend: _backend,
      unavailableReason: _passThroughReason,
      warn: _warn,
    );
  }

  /// The backend this runner resolved to (startup diagnostics).
  SandboxBackend get backend => _backend;

  /// Why this runner is a pass-through, or null when a backend is active.
  String? get passThroughReason {
    if (_backend != SandboxBackend.passThrough) return null;
    return _passThroughReason ??
        sandboxPassThroughReasonFor(
          isMacOS: Platform.isMacOS,
          isLinux: Platform.isLinux,
          osName: Platform.operatingSystem,
          sandboxEnabled: _enabled,
          sandboxExecPresent: sandboxExecAvailable,
          bwrapPresent: bwrapOnPath,
          userNsEnabled: userNamespacesEnabled,
        );
  }

  /// One-line description of the resolved backend, for the startup log.
  String get backendDescription => describeSandboxBackend(
        _backend,
        passThroughReason: passThroughReason,
      );

  @override
  Future<RunningProcess> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    final wrapped = _wrap(executable, arguments);
    if (wrapped == null) {
      return _inner.start(executable, arguments,
          workingDirectory: workingDirectory, environment: environment ?? this.environment);
    }
    return _inner.start(wrapped.$1, wrapped.$2,
        workingDirectory: workingDirectory, environment: environment ?? this.environment);
  }

  @override
  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final wrapped = _wrap(executable, arguments);
    if (wrapped == null) {
      return _inner.run(executable, arguments,
          workingDirectory: workingDirectory, environment: environment ?? this.environment);
    }
    return _inner.run(wrapped.$1, wrapped.$2,
        workingDirectory: workingDirectory, environment: environment ?? this.environment);
  }

  /// The (executable, argv) to actually spawn, or null for pass-through.
  (String, List<String>)? _wrap(String executable, List<String> arguments) {
    switch (_backend) {
      case SandboxBackend.sandboxExec:
        final profile = buildSandboxProfile(
          projectRoot: _projectRoot,
          sandboxNet: _sandboxNet,
          extraAllowPaths: accessPolicy.writablePaths,
          sandboxReadOnly: _sandboxReadOnly,
        );
        return ('sandbox-exec', ['-p', profile, executable, ...arguments]);
      case SandboxBackend.bwrap:
        final args = buildBwrapArgs(
          projectRoot: _projectRoot,
          tempDirs: _defaultBwrapTempDirs(environment),
          extraAllowPaths: accessPolicy.writablePaths,
          sandboxNet: _sandboxNet,
          sandboxReadOnly: _sandboxReadOnly,
        );
        return ('bwrap', [...args, executable, ...arguments]);
      case SandboxBackend.passThrough:
        _warnPassThrough();
        return null;
    }
  }

  void _warnPassThrough() {
    // A deliberate disable (--no-sandbox) is the user's call, not a
    // degradation — only a missing backend warrants the warning.
    if (!_enabled || _warnedAboutUnavailable) return;
    _warnedAboutUnavailable = true;
    _warn('sandbox unavailable (${passThroughReason ?? 'no backend'}); bash '
        'subprocesses run unsandboxed. The denylist + permission gate still '
        'apply.');
  }
}
