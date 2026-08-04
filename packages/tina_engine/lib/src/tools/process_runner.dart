import 'dart:io' show Process;

import 'process_registry.dart';

/// The decoded outcome of a non-interactive [ProcessRunner.run]. [stdout] and
/// [stderr] are strings (decoded with the platform default encoding, matching
/// `dart:io`'s [Process.run]); the raw byte form is never needed by callers.
///
/// Named [RunResult] rather than `ProcessResult` to avoid clashing with
/// `dart:io`'s type of that name inside [IoProcessRunner].
class RunResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  const RunResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });
}

/// A process started via [ProcessRunner.start]. This is the slice of
/// `dart:io`'s [Process] the streaming tools (bash, grep) depend on: live
/// stdout/stderr byte streams, an exit-code future, and a kill handle.
abstract class RunningProcess {
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  Future<int> get exitCode;

  /// The OS process id. Exposed so callers (bash's cancel/timeout) can kill the
  /// whole descendant tree rather than just this direct child — see
  /// `killProcessTree`. Meaningless for in-memory test doubles.
  int get pid;

  /// Signal the process to terminate. Returns whether a signal could be
  /// delivered. Carries no signal argument because every call site uses the
  /// default (SIGTERM) semantics of `dart:io`'s bare `Process.kill()`; keeping
  /// `ProcessSignal` off the interface leaves the seam free of `dart:io`.
  bool kill();
}

/// Hides `dart:io` process spawning behind a testable seam. Streaming tools
/// (bash, grep) call [start] for live output plus cancellation; probing call
/// sites (e.g. grep's `rg --version` availability check) use [run].
///
/// Tools take an [IoProcessRunner] by default; tests inject a fake that
/// scripts stdout/stderr/exitCode/kill deterministically.
abstract class ProcessRunner {
  Future<RunningProcess> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  });

  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  });
}

/// [ProcessRunner] over real `dart:io`. A thin wrapper with no added behavior.
class IoProcessRunner implements ProcessRunner {
  const IoProcessRunner();

  @override
  Future<RunningProcess> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    final proc = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
    // Register so the process is reaped on exit (a backgrounded descendant
    // shouldn't outlive the session). Unregistered when [exitCode] completes.
    ChildProcessRegistry.instance.track(proc.pid);
    return _IoRunningProcess(proc);
  }

  @override
  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    final r = await Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
    return RunResult(
      exitCode: r.exitCode,
      stdout: r.stdout as String,
      stderr: r.stderr as String,
    );
  }
}

class _IoRunningProcess implements RunningProcess {
  final Process _proc;
  _IoRunningProcess(this._proc);

  @override
  Stream<List<int>> get stdout => _proc.stdout;
  @override
  Stream<List<int>> get stderr => _proc.stderr;
  @override
  int get pid => _proc.pid;
  @override
  Future<int> get exitCode =>
      _proc.exitCode.whenComplete(() => ChildProcessRegistry.instance.untrack(pid));
  @override
  bool kill() => _proc.kill();
}
