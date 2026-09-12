// Spawns and supervises plugin-worker processes (bin/worker.dart). This is the
// ONLY sanctioned way to run a guest: guests never execute on the agent or UI
// isolate (tin-w4sm required constraints). The supervisor owns the worker
// process; cancellation and teardown join all owned work — a worker is "done"
// when its process has exited and been reaped, not when a reply arrives.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One supervised worker process. Not reusable: [stop] terminates it.
final class PluginWorkerSupervisor {
  PluginWorkerSupervisor();

  Process? _process;
  Process? get process => _process;
  int? get workerPid => _process?.pid;

  final _replies = <int, Completer<Map<String, Object?>>>{};
  StreamSubscription<String>? _stdoutSub;
  var _nextId = 1;
  var _stopped = false;

  static const _startTimeout = Duration(seconds: 60);
  static const _stopGrace = Duration(seconds: 10);

  /// Starts the worker process. [dartBin] is overridable for tests.
  Future<void> start({String dartBin = 'dart'}) async {
    if (_process != null) {
      throw StateError('worker already started');
    }
    var packageRoot = Directory.current.path;
    // Search upward so tests running from packages/dart_wasmtime still find
    // the repo-root package layout.
    while (!File('$packageRoot/packages/dart_wasmtime/bin/worker.dart')
        .existsSync()) {
      final parent = File(packageRoot).parent.path;
      if (parent == packageRoot) {
        throw StateError(
            'worker.dart not found above ${Directory.current.path}');
      }
      packageRoot = parent;
    }
    final workerScript =
        '$packageRoot/packages/dart_wasmtime/bin/worker.dart';
    final process = await Process.start(
      dartBin,
      ['run', workerScript],
      workingDirectory: packageRoot,
      environment: {
        ...Platform.environment,
        // Keep the worker from picking up an interactive parent's stdout.
        'DART_WASMTIME_WORKER': '1',
      },
      // stderr is piped, never inherited: crash text must not interleave with
      // the agent's own output.
      mode: ProcessStartMode.normal,
    );
    _process = process;

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.trim().isEmpty) {
        return;
      }
      try {
        final msg = jsonDecode(line) as Map<String, Object?>;
        final id = msg['id'] as int?;
        if (id == null) {
          return;
        }
        final c = _replies.remove(id);
        if (c != null && !c.isCompleted) {
          c.complete(msg);
        }
      } on FormatException {
        // Non-protocol output on stdout is a worker bug; drop it rather than
        // wedge the supervisor. The test harness asserts none of this happens.
      }
    });

    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      // Kept for crash forensics; never parsed as protocol.
      lastStderrLine = line;
    });

    // The process exiting resolves every outstanding reply with failure and
    // completes _exited — replies alone are not proof of teardown.
    _exited = process.exitCode.then((code) {
      _exitCode = code;
      for (final c in _replies.values) {
        if (!c.isCompleted) {
          c.completeError(
              StateError('worker exited (code=$code) with a call in flight'));
        }
      }
      _replies.clear();
    });
  }

  String? _lastStderrLine;
  String? get lastStderrLine => _lastStderrLine;
  set lastStderrLine(String? v) => _lastStderrLine = v;

  /// Resolves only when the worker process is really gone (reaped).
  Future<void> get exited => _exited ?? Future.value();
  Future<void>? _exited;
  int? _exitCode;
  int? get exitCodeOf => _exitCode;

  Future<Map<String, Object?>> _request(
      String method, [Map<String, Object?>? params]) {
    if (_stopped) {
      throw StateError('worker stopped');
    }
    final p = _process;
    if (p == null) {
      throw StateError('worker not started');
    }
    final id = _nextId++;
    final c = Completer<Map<String, Object?>>();
    _replies[id] = c;
    p.stdin.writeln(jsonEncode({'id': id, 'method': method, ...?params}));
    return c.future;
  }

  Future<Map<String, Object?>> ping() async {
    final r = await _request('ping').timeout(_startTimeout);
    if (r['ok'] != true) {
      throw StateError('ping failed: $r');
    }
    return r;
  }

  /// Compiles + instantiates a guest module in the worker.
  Future<void> load(List<int> guestBytes) async {
    final r = await _request('load', {
      'bytes_base64': base64Encode(guestBytes),
    }).timeout(const Duration(minutes: 5));
    if (r['ok'] != true) {
      throw StateError('load failed: ${r['error']}');
    }
  }

  Future<int> call(String name, List<int> args) async {
    final r = await _request('call', {
      'name': name,
      'args': args,
    }).timeout(const Duration(minutes: 5));
    if (r['ok'] == true) {
      return (r['result'] as Map)['value'] as int;
    }
    throw WorkerCallException(r['error'] as String? ?? 'call failed');
  }

  /// Cancels the in-flight call. Returns after the worker acknowledged the
  /// cancel; [stop] then joins the process. The guest stops at its next epoch
  /// deadline — measured at tens of microseconds after the bump.
  Future<void> cancel() async {
    await _request('cancel');
  }

  /// Joins all owned work: asks the worker to shut down, waits up to
  /// [_stopGrace] for the process to exit, then kills and reaps it. Never
  /// leaves a worker behind.
  Future<void> stop() async {
    if (_stopped) {
      return;
    }
    final p = _process;
    if (p == null) {
      _stopped = true;
      return;
    }
    try {
      // NOTE: _stopped is only set AFTER the shutdown request: _request
      // rejects requests once stopped, and setting it first silently
      // swallowed the shutdown line — stop() then waited out the whole grace
      // period and SIGKILLed a perfectly healthy worker (observed as exit
      // code -9 after a fixed ~10s).
      await _request('shutdown').timeout(_stopGrace);
    } on Object {
      // Worker hung or died: fall through to kill + reap below.
    }
    _stopped = true;
    // Wait for the real exit (join), with a hard kill as backstop.
    final exited = p.exitCode.timeout(_stopGrace, onTimeout: () {
      p.kill(ProcessSignal.sigkill);
      return p.exitCode;
    });
    await exited;
    await _stdoutSub?.cancel();
    _stdoutSub = null;
    _process = null;
  }
}

class WorkerCallException implements Exception {
  WorkerCallException(this.message);
  final String message;
  @override
  String toString() => 'WorkerCallException: $message';
}
