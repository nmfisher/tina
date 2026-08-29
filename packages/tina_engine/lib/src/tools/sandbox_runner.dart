import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'process_runner.dart';

final _log = Logger('tina.sandbox');

/// True when macOS `sandbox-exec` is available to confine subprocess writes.
/// One of the probes [resolveSandboxBackend] consults; kept as a getter so
/// tests on macOS exercise the real path.
bool get sandboxExecAvailable =>
    Platform.isMacOS && File('/usr/bin/sandbox-exec').existsSync();

/// Canonical system directories the Linux sandbox mounts read-only: visible
/// inside the namespace so toolchains/compilers keep working, but not
/// writable. Each is bound only when it exists on the host (bwrap fails on a
/// missing source). `$HOME` is deliberately NOT in this set — bwrap is
/// namespace-first, so an unmounted home is simply invisible (see
/// docs/features/sandbox.md).
const List<String> kLinuxSandboxReadOnlyBinds = <String>[
  '/usr',
  '/bin',
  '/sbin',
  '/lib',
  '/lib64',
  '/etc',
  '/opt',
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

/// Why the sandbox degrades to [SandboxBackend.passThrough] on a given host,
/// or null when a real backend is active. Same shape as
/// [resolveSandboxBackendFor] so tests can drive every branch.
String? sandboxPassThroughReasonFor({
  required bool isMacOS,
  required bool isLinux,
  required String osName,
  bool sandboxEnabled = true,
  bool sandboxExecPresent = false,
  bool bwrapPresent = false,
  bool userNsEnabled = true,
}) {
  if (!sandboxEnabled) return 'explicitly disabled (--no-sandbox)';
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
      'bwrap (Linux): bash confined to read-only system dirs + writable '
          'project/temp; home and the rest of the filesystem are not mounted',
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

  final sb = StringBuffer('(version 1)\n');
  sb.write('(allow default)\n'); // reads, network, process — unrestricted
  sb.write('(deny file-write*)\n'); // …then deny every write, re-granting below
  if (sandboxReadOnly) {
    sb.write('(deny file-read* (subpath "/Users"))\n');
    if (root != null) {
      sb.write('(allow file-read* (subpath "${_escape(root)}"))\n');
    }
  }
  for (final path in allow) {
    sb.write('(allow file-write* (subpath "${_escape(path)}"))\n');
  }
  return sb.toString();
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
  final args = <String>[];
  // System directories, read-only. Missing dirs are skipped: bwrap aborts on
  // a missing source, and a missing /lib64 must never break the sandbox.
  for (final dir in readOnlyBinds) {
    if (Directory(dir).existsSync()) args.addAll(['--ro-bind', dir, dir]);
  }
  // Temp: the real temp trees bound read-write (parity with the macOS
  // profile's /private/var/folders + /tmp grants).
  final temps = <String>{}; // ordered; resolves to the same real path dedupe
  for (final t in tempDirs ?? _defaultBwrapTempDirs()) {
    final r = _resolve(t);
    if (r != null) {
      temps.add(r);
    } else {
      _log.warning('sandbox: ignoring unresolvable temp dir "$t"');
    }
  }
  for (final t in temps) {
    args.addAll(['--bind', t, t]);
  }
  // The project root. Bind order matters under bwrap — a later mount shadows
  // an earlier nested one — so the project goes before the extras below and
  // an extra grant inside the project stays writable even under
  // [sandboxReadOnly].
  final root = _resolve(projectRoot);
  if (root != null) {
    args.addAll([sandboxReadOnly ? '--ro-bind' : '--bind', root, root]);
  } else {
    _log.warning(
        'sandbox: project root "$projectRoot" unresolvable; proceeding '
        'without it');
  }
  // TINA_SANDBOX_ALLOW extras: explicit writable grants, same as the macOS
  // profile's re-grants — bound LAST so they win, even inside a read-only
  // project or over a read-only system dir.
  for (final e in extraAllowPaths) {
    final r = _resolve(e);
    if (r != null) {
      args.addAll(['--bind', r, r]);
    } else {
      _log.warning('sandbox: ignoring unresolvable allow-path "$e"');
    }
  }
  // Pseudo-devices a normal command touches, provided fresh by bwrap.
  args.addAll(['--dev', '/dev', '--proc', '/proc']);
  if (sandboxNet) args.add('--unshare-net');
  return args..add('--'); // end of options; the command follows
}

List<String> _defaultBwrapTempDirs() {
  final tmp = Platform.environment['TMPDIR'];
  return [
    if (tmp != null && tmp.isNotEmpty) tmp,
    '/tmp',
    '/var/tmp',
    Directory.systemTemp.path,
  ];
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

String _escape(String s) => s.replaceAll('\\', r'\\').replaceAll('"', r'\"');

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
  final String _projectRoot;
  final List<String> _extraAllowPaths;
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
    required String projectRoot,
    List<String> extraAllowPaths = const [],
    bool? enabled, // false = deliberate disable (--no-sandbox / tests)
    bool sandboxNet = false,
    bool sandboxReadOnly = false,
    SandboxBackend? backend, // test override; defaults to [resolveSandboxBackend]
    String? unavailableReason, // test override; defaults to [sandboxPassThroughReason]
    void Function(String message)? warn, // test sink; defaults to the logger
  })  : _inner = inner ?? const IoProcessRunner(),
        _projectRoot = projectRoot,
        _extraAllowPaths = extraAllowPaths,
        _enabled = enabled ?? true,
        _sandboxNet = sandboxNet,
        _sandboxReadOnly = sandboxReadOnly,
        _backend = backend ?? resolveSandboxBackend(sandboxEnabled: enabled ?? true),
        _passThroughReason = unavailableReason,
        _warn = warn ?? _log.warning;

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
  }) {
    final wrapped = _wrap(executable, arguments);
    if (wrapped == null) {
      return _inner.start(executable, arguments,
          workingDirectory: workingDirectory);
    }
    return _inner.start(wrapped.$1, wrapped.$2,
        workingDirectory: workingDirectory);
  }

  @override
  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    final wrapped = _wrap(executable, arguments);
    if (wrapped == null) {
      return _inner.run(executable, arguments, workingDirectory: workingDirectory);
    }
    return _inner.run(wrapped.$1, wrapped.$2, workingDirectory: workingDirectory);
  }

  /// The (executable, argv) to actually spawn, or null for pass-through.
  (String, List<String>)? _wrap(String executable, List<String> arguments) {
    switch (_backend) {
      case SandboxBackend.sandboxExec:
        final profile = buildSandboxProfile(
          projectRoot: _projectRoot,
          extraAllowPaths: _extraAllowPaths,
          sandboxReadOnly: _sandboxReadOnly,
        );
        return ('sandbox-exec', ['-p', profile, executable, ...arguments]);
      case SandboxBackend.bwrap:
        final args = buildBwrapArgs(
          projectRoot: _projectRoot,
          extraAllowPaths: _extraAllowPaths,
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
