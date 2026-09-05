import 'dart:async';
import 'dart:convert';

import 'package:tina_engine/tina_engine.dart';

/// A scripted [RunningProcess] for tests.
///
/// Each entry of [stdoutChunks]/[stderrChunks] is emitted verbatim as one
/// UTF-8 byte chunk on the corresponding stream (in order), then both streams
/// close and [exitCode] completes with [exitCodeValue]. Emit happens on the
/// next microtask so the caller can attach listeners after [start] returns.
///
/// When [hangUntilKilled] is true the process never self-completes: the streams
/// stay open and [exitCode] stays pending until [kill] is called — modelling a
/// long-running command that bash's timeout/cancel must terminate. On kill the
/// streams close and [exitCode] completes with [exitCodeValue] (set this
/// non-zero — e.g. 143 — so a timeout-driven kill surfaces as a non-zero exit,
/// matching real SIGTERM behaviour).
///
/// Setting [killCompletesExit] to false models a process that survives its
/// kill signal (stuck in D-state, or a SIGKILL-proof descendant): `kill()` is
/// recorded (both [killed] and [forceKilled]) but nothing closes — [exitCode]
/// stays pending, so a caller racing a post-kill grace window wins the race.
class MemoryRunningProcess implements RunningProcess {
  final List<String> stdoutChunks;
  final List<String> stderrChunks;
  final int exitCodeValue;
  final bool hangUntilKilled;
  final bool killCompletesExit;

  /// Fake pid for the [RunningProcess.pid] seam. Meaningless in-memory; tests
  /// that exercise tree-kill can set it, otherwise it stays 0.
  final int pid;

  final _out = StreamController<List<int>>();
  final _err = StreamController<List<int>>();
  final Completer<int> _exit = Completer<int>();

  bool killed = false;

  /// Set when `kill()` arrived with `force: true` (bash_tool's escalation).
  bool forceKilled = false;

  MemoryRunningProcess({
    this.stdoutChunks = const [],
    this.stderrChunks = const [],
    this.exitCodeValue = 0,
    this.hangUntilKilled = false,
    this.killCompletesExit = true,
    this.pid = 0,
  }) {
    scheduleMicrotask(_pump);
  }

  void _pump() {
    if (_out.isClosed) return; // killed before this microtask ran
    for (final chunk in stdoutChunks) {
      _out.add(utf8.encode(chunk));
    }
    for (final chunk in stderrChunks) {
      _err.add(utf8.encode(chunk));
    }
    if (hangUntilKilled || !killCompletesExit) return; // wait for kill()
    _close();
  }

  void _close() {
    if (!_out.isClosed) _out.close();
    if (!_err.isClosed) _err.close();
    if (!_exit.isCompleted) _exit.complete(exitCodeValue);
  }

  @override
  Stream<List<int>> get stdout => _out.stream;
  @override
  Stream<List<int>> get stderr => _err.stream;
  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill({bool force = false}) {
    killed = true;
    if (force) forceKilled = true;
    if (!killCompletesExit) return true; // survives its kill signal
    _close();
    return true;
  }
}

/// Builds the [RunningProcess] a [MemoryProcessRunner] hands back for a given
/// executable + argv. Tests inspect [arguments] to route (e.g. `rg --version`
/// vs `rg <search>`).
typedef MemoryProcessFactory = MemoryRunningProcess Function(
  String executable,
  List<String> arguments,
);

/// A [ProcessRunner] that builds each process via [factory] and records every
/// [start]/[run] invocation. Both methods consult the same factory so a test
/// can script `rg --version` (run) and `rg <args>` (start) independently by
/// branching on [arguments] inside the factory.
class MemoryProcessRunner implements ProcessRunner {
  final MemoryProcessFactory factory;

  final List<({String executable, List<String> arguments})> starts = [];
  final List<({String executable, List<String> arguments})> runs = [];

  /// Every process this runner handed out from [start], in order — lets tests
  /// assert on kill bookkeeping ([MemoryRunningProcess.killed] and friends).
  final List<MemoryRunningProcess> processes = [];

  MemoryProcessRunner(this.factory);

  /// Convenience for the common case: every invocation returns the same
  /// scripted process regardless of executable/argv.
  MemoryProcessRunner.always(MemoryRunningProcess proc) : this(_always(proc));

  static MemoryProcessFactory _always(MemoryRunningProcess proc) =>
      (String executable, List<String> arguments) => proc;

  @override
  Future<RunningProcess> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    starts.add((executable: executable, arguments: arguments));
    final proc = factory(executable, arguments);
    processes.add(proc);
    return proc;
  }

  @override
  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    runs.add((executable: executable, arguments: arguments));
    final p = factory(executable, arguments);
    final out = await p.stdout.transform(utf8.decoder).join();
    final err = await p.stderr.transform(utf8.decoder).join();
    final code = await p.exitCode;
    return RunResult(exitCode: code, stdout: out, stderr: err);
  }
}
