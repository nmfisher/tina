import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'process_runner.dart';

final _log = Logger('tina.sandbox');

/// True when macOS `sandbox-exec` is available to confine subprocess writes.
/// On Linux (no `bwrap` here) the [SandboxedProcessRunner] is a no-op — the
/// bash denylist + permission gate still apply, but there is no OS-level write
/// containment. Evaluated once.
bool get sandboxExecAvailable =>
    Platform.isMacOS && File('/usr/bin/sandbox-exec').existsSync();

/// Build a `sandbox-exec -p` profile that confines file *writes* to the project
/// root, the OS temp tree, a couple of pseudo-devices, and any [extraAllowPaths]
/// — while leaving reads, network, and process spawning unrestricted. This is
/// the structural guard against a runaway `rm`/`find -delete`/etc. reaching
/// outside the project: unlike the denylist (a regex on raw shell) it can't be
/// routed around with `python3 -c` or `base64 -d | sh`.
///
/// Paths are resolved to their real form first so `/tmp`→`/private/tmp` and
/// symlinked roots are matched correctly by sandbox-exec's `(subpath …)`. A
/// path that can't be resolved is skipped (with a log) rather than embedded
/// verbatim — a bad allow-path must never silently widen or break the profile.
String buildSandboxProfile({
  required String projectRoot,
  List<String> extraAllowPaths = const [],
}) {
  final allow = <String>{};
  // The project root is the one path the agent must be able to write to.
  final root = _resolve(projectRoot);
  if (root != null) allow.add(root);
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
  for (final path in allow) {
    sb.write('(allow file-write* (subpath "${_escape(path)}"))\n');
  }
  return sb.toString();
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

/// A [ProcessRunner] decorator that runs every command under `sandbox-exec` on
/// macOS, confining subprocess writes to the project root + temp (see
/// [buildSandboxProfile]). Reads/network/process stay open. When sandbox-exec
/// is unavailable (non-macOS) it is a transparent pass-through.
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

  bool _warnedAboutUnavailable = false;

  SandboxedProcessRunner({
    ProcessRunner? inner,
    required String projectRoot,
    List<String> extraAllowPaths = const [],
    bool? enabled, // test override; defaults to [sandboxExecAvailable]
  })  : _inner = inner ?? const IoProcessRunner(),
        _projectRoot = projectRoot,
        _extraAllowPaths = extraAllowPaths,
        _enabled = enabled ?? sandboxExecAvailable;

  @override
  Future<RunningProcess> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) {
    if (!_enabled) {
      _warnUnavailable();
      return _inner.start(executable, arguments,
          workingDirectory: workingDirectory);
    }
    final profile = buildSandboxProfile(
        projectRoot: _projectRoot, extraAllowPaths: _extraAllowPaths);
    return _inner.start(
      'sandbox-exec',
      ['-p', profile, executable, ...arguments],
      workingDirectory: workingDirectory,
    );
  }

  @override
  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    if (!_enabled) {
      _warnUnavailable();
      return _inner.run(executable, arguments, workingDirectory: workingDirectory);
    }
    final profile = buildSandboxProfile(
        projectRoot: _projectRoot, extraAllowPaths: _extraAllowPaths);
    return _inner.run(
      'sandbox-exec',
      ['-p', profile, executable, ...arguments],
      workingDirectory: workingDirectory,
    );
  }

  void _warnUnavailable() {
    if (_warnedAboutUnavailable) return;
    _warnedAboutUnavailable = true;
    _log.warning('sandbox-exec unavailable; bash subprocesses run unsandboxed. '
        'The denylist + permission gate still apply.');
  }
}
