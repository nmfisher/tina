/// Native PTY transport. Launch and I/O stay on a worker isolate; session
/// shutdown completes before final output and process status are published.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import '../tools/process_registry.dart';
import 'pty_output.dart';
import 'pty_session.dart';
import 'pty_shim_bindings.dart';

/// Launch request for [PtyRunner.spawn].
class PtySpawnRequest {
  /// Resolved executable path (no PATH search happens in the shim).
  final String executable;

  /// Arguments excluding argv[0]; the runner prepends the executable.
  final List<String> arguments;

  /// Working directory for the child. Must exist or spawn fails with a
  /// structured error.
  final String? workingDirectory;

  /// Extra environment entries layered over an empty environment. The child
  /// does NOT inherit tina's full environment: pass what it needs (`TERM`,
  /// `PATH`, `HOME`, ...). Kept explicit so secrets cannot leak by accident.
  final Map<String, String> environment;

  /// Initial terminal size. Both must be > 0.
  final int rows;
  final int cols;

  const PtySpawnRequest({
    required this.executable,
    this.arguments = const [],
    this.workingDirectory,
    this.environment = const {},
    this.rows = 24,
    this.cols = 80,
  });
}

/// Why a [PtyException] was raised.
enum PtyErrorKind {
  /// The executable could not be exec'd (missing, not executable, ...).
  executable,

  /// The requested working directory could not be entered.
  workingDirectory,

  /// The shim or OS refused the spawn for another reason.
  spawn,
}

/// A structured launch failure. The child never ran (or exec failed), so
/// there is nothing to clean up.
class PtyException implements Exception {
  final PtyErrorKind kind;
  final int errno;
  final String message;
  const PtyException(this.kind, this.errno, this.message);

  @override
  String toString() => 'PtyException($kind, errno=$errno): $message';
}

/// Whether this platform has a PTY backend. The engine as a whole stays
/// importable and usable everywhere; only [PtyRunner.spawn] is limited.
bool get ptySupported {
  if (!Platform.isLinux && !Platform.isMacOS) return false;
  try {
    return tina_shim_abi_version() == 2;
  } catch (_) {
    return false; // native asset missing/stale
  }
}

/// One worker per connection. The output window bounds unconsumed transport
/// bytes, including messages in flight between isolates.
class PtyRunner {
  final int maxQueuedWrites;
  final int maxQueuedOutput;
  final ChildProcessRegistry? registry;
  const PtyRunner(
      {this.maxQueuedWrites = 256 * 1024,
      this.maxQueuedOutput = 256 * 1024,
      this.registry});

  Future<PtyConnection> spawn(PtySpawnRequest request) async {
    if (maxQueuedWrites <= 0 || maxQueuedOutput <= 0) {
      throw ArgumentError('PTY queue limits must be positive');
    }
    final worker = await _PtyWorker.spawn(
        request, maxQueuedOutput, registry ?? ChildProcessRegistry.instance);
    return PtyConnection._(worker, math.min(maxQueuedWrites, 65536));
  }
}

class PtyConnection {
  final _PtyWorker _worker;
  final int _writeChunkSize;
  Future<void> _writes = Future.value();
  Future<int>? _closing;
  PtyConnection._(this._worker, this._writeChunkSize);

  int get pid => _worker.pid;
  bool get exited => _worker.exited;

  /// One ordered byte stream. Bytes produced before the listener attaches are
  /// retained, including after natural exit. Pausing stops credit replenishment
  /// and therefore stops native reads. Cancelling explicitly abandons output.
  Stream<Uint8List> get output => _worker.output.stream;

  /// Process exited, owned descendants terminated, native output drained into
  /// the bounded channel, and descriptors released. A paused/late consumer can
  /// still read its retained bytes before its stream's done event.
  Future<int> get done => _worker.done.future;

  /// Ordered writes, with at most one bounded chunk in flight. True means all
  /// bytes reached the PTY; false means exit/close interrupted delivery. All
  /// waiting writers settle on every terminal path.
  Future<bool> write(List<int> bytes) {
    if (_closing != null || _worker.finalized) return Future.value(false);
    final snapshot = Uint8List.fromList(bytes);
    final result = Completer<bool>();
    _writes = _writes.then((_) async {
      try {
        for (var offset = 0;
            offset < snapshot.length;
            offset += _writeChunkSize) {
          if (_closing != null || _worker.finalized) {
            result.complete(false);
            return;
          }
          final end = math.min(offset + _writeChunkSize, snapshot.length);
          if (!await _worker
              .write(Uint8List.sublistView(snapshot, offset, end))) {
            result.complete(false);
            return;
          }
        }
        result.complete(!_worker.finalized && _closing == null);
      } catch (e, st) {
        result.completeError(e, st);
      }
    });
    return result.future;
  }

  void resize(int rows, int cols) => _worker.send([_Cmd.resize, rows, cols]);

  Future<int> close({Duration grace = const Duration(seconds: 2)}) =>
      _closing ??= _worker.terminate(grace);
}

enum _Cmd { write, resize, terminate, credit }

enum _Msg { ready, output, written, exited, finished, failure }

class _SpawnConfig {
  final PtySpawnRequest request;
  final int outputWindow;
  final SendPort events;
  const _SpawnConfig(this.request, this.outputWindow, this.events);
}

class _PtyWorker {
  final ReceivePort _events = ReceivePort();
  final ChildProcessRegistry registry;
  final Completer<_PtyWorker> _ready = Completer();
  final Completer<int> done = Completer();
  final Map<int, Completer<bool>> _writes = {};
  late final PtyOutput output;
  SendPort? _commands;
  int pid = -1;
  int _nextWrite = 0;
  bool exited = false;
  bool finalized = false;

  _PtyWorker(this.registry) {
    output = PtyOutput(onConsumed: (bytes) => send([_Cmd.credit, bytes]));
    _events.listen(_onEvent);
  }

  static Future<_PtyWorker> spawn(PtySpawnRequest request, int window,
      ChildProcessRegistry registry) async {
    final worker = _PtyWorker(registry);
    try {
      // Handshake, output, final status, errors and death use ONE mailbox.
      // No cross-port race can discard queued output or the final exit code.
      await Isolate.spawn(
          _workerMain, _SpawnConfig(request, window, worker._events.sendPort),
          onExit: worker._events.sendPort, onError: worker._events.sendPort);
    } catch (_) {
      worker._events.close();
      rethrow;
    }
    return worker._ready.future;
  }

  void send(List<Object> message) {
    if (!finalized) _commands?.send(message);
  }

  Future<bool> write(Uint8List bytes) {
    if (finalized) return Future.value(false);
    final id = _nextWrite++;
    final completer = Completer<bool>();
    _writes[id] = completer;
    send([_Cmd.write, id, bytes]);
    return completer.future;
  }

  Future<int> terminate(Duration grace) {
    send([_Cmd.terminate, math.max(0, grace.inMicroseconds)]);
    return done.future;
  }

  void _onEvent(dynamic event) {
    if (event == null || event is! List || event.first is! _Msg) {
      if (!finalized) {
        final error =
            StateError('PTY worker exited without final status: $event');
        // This only covers an unexpected isolate failure. Normal errors are
        // caught in the worker, which owns descriptor cleanup and final status.
        unawaited(_recover(error));
      }
      return;
    }
    switch (event[0] as _Msg) {
      case _Msg.ready:
        pid = event[1] as int;
        _commands = event[2] as SendPort;
        registry.track(pid, terminate: (grace) async {
          await terminate(grace);
        });
        _ready.complete(this);
      case _Msg.output:
        output.add(event[1] as Uint8List);
      case _Msg.written:
        _writes.remove(event[1] as int)?.complete(event[2] as bool);
      case _Msg.exited:
        exited = true;
      case _Msg.finished:
        final error = event[2] as String?;
        if (error != null) output.addError(StateError(error));
        _finish(event[1] as int);
      case _Msg.failure:
        if (!_ready.isCompleted) {
          _ready.completeError(PtyException(
              event[1] as PtyErrorKind, event[2] as int, event[3] as String));
        }
        _finish(-1);
    }
  }

  bool _recovering = false;
  Future<void> _recover(Object error) async {
    if (_recovering) return;
    _recovering = true;
    Object problem = error;
    try {
      if (pid > 0) {
        final session = pid;
        await Isolate.run(
            () => _nativeSession(session).terminate(grace: Duration.zero));
      }
    } catch (cleanupError) {
      problem = StateError('$error; cleanup: $cleanupError');
    } finally {
      if (!_ready.isCompleted) {
        _ready.completeError(problem);
      } else {
        output.addError(problem);
      }
      _finish(-1);
    }
  }

  void _finish(int code) {
    if (finalized) return;
    finalized = true;
    exited = true;
    registry.untrack(pid);
    for (final pending in _writes.values) {
      pending.complete(false);
    }
    _writes.clear();
    output.finish();
    _events.close();
    // Let an active listener receive its queued output/done before waiters.
    scheduleMicrotask(() {
      if (!done.isCompleted) done.complete(code);
    });
  }
}

PtySession _nativeSession(int sid) => PtySession(signal: (sig) {
      final result = tina_pty_signal_session(sid, sig);
      if (result < 0)
        throw StateError('PTY session signal failed: errno ${-result}');
      return result;
    });

Future<void> _workerMain(_SpawnConfig config) async {
  final req = malloc<TinaPtySpawnRequest>();
  final out = malloc<TinaPtySpawnResult>();
  final request = config.request;
  final strings = <Pointer<Uint8>>[];
  Pointer<Uint8> string(String value) {
    final bytes = utf8.encode(value);
    final p = malloc<Uint8>(bytes.length + 1);
    p.asTypedList(bytes.length + 1)
      ..setRange(0, bytes.length, bytes)
      ..[bytes.length] = 0;
    strings.add(p);
    return p;
  }

  Pointer<Pointer<Uint8>>? argv;
  Pointer<Pointer<Uint8>>? env;
  var spawned = false;
  try {
    req.ref.executable = string(request.executable);
    argv =
        buildCStringArray([request.executable, ...request.arguments], malloc);
    env = buildCStringArray(
        request.environment.entries.map((e) => '${e.key}=${e.value}').toList(),
        malloc);
    req.ref.argv = argv;
    req.ref.env = env;
    req.ref.cwd = request.workingDirectory == null
        ? nullptr
        : string(request.workingDirectory!);
    req.ref.rows = request.rows;
    req.ref.cols = request.cols;
    final rc = tina_pty_spawn(req, out);
    if (rc < 0 || out.ref.error != 0) {
      final errno = rc < 0 ? -rc : out.ref.error;
      config.events.send([
        _Msg.failure,
        PtyErrorKind.spawn,
        errno,
        'Cannot launch ${request.executable} in ${request.workingDirectory}: errno $errno'
      ]);
      return;
    }
    spawned = true;
    await _runLoop(config, out.ref.pid, out.ref.masterFd, out.ref.statusFd);
  } catch (error) {
    // _runLoop owns all post-spawn cleanup and reports its own failures.
    if (!spawned)
      config.events.send([_Msg.failure, PtyErrorKind.spawn, 0, '$error']);
  } finally {
    for (final p in strings) {
      malloc.free(p);
    }
    if (argv != null) freeCStringArray(argv, malloc);
    if (env != null) freeCStringArray(env, malloc);
    malloc.free(req);
    malloc.free(out);
  }
}

Future<void> _runLoop(
    _SpawnConfig config, int pid, int fd, int statusFd) async {
  final commands = ReceivePort();
  final buffer = malloc<Uint8>(65536);
  final scratch = malloc<Uint8>(65536);
  final status = malloc<Int32>();
  var credit = config.outputWindow;
  var childGone = false;
  var rawStatus = -1;
  var code = -1;
  String? failure;
  Duration? requestedGrace;
  Future<void>? shutdown;
  var shutdownDone = false;
  Object? shutdownError;
  Uint8List? writing;
  var writeId = -1;
  var writeOffset = 0;

  void settleWrite(bool delivered) {
    if (writing == null) return;
    config.events.send([_Msg.written, writeId, delivered]);
    writing = null;
    writeOffset = 0;
  }

  void startShutdown(Duration grace) {
    if (shutdown != null) return;
    // Catch into state immediately; the loop awaits this same future before
    // finalization. No detached timeout or timer can kill cleanup midway.
    shutdown = _nativeSession(pid).terminate(grace: grace).then((_) {
      shutdownDone = true;
    }, onError: (Object error) {
      shutdownError = error;
      shutdownDone = true;
    });
  }

  void reap() {
    if (childGone) return;
    final rc = tina_pty_reap(statusFd, status, 0);
    if (rc == 0) return;
    childGone = true;
    rawStatus = rc > 0 ? status.value : -1;
    settleWrite(false);
    config.events.send([_Msg.exited]);
  }

  commands.listen((dynamic message) {
    final m = message as List;
    switch (m[0] as _Cmd) {
      case _Cmd.credit:
        credit += m[1] as int;
      case _Cmd.terminate:
        requestedGrace ??= Duration(microseconds: m[1] as int);
      case _Cmd.resize:
        tina_pty_resize(fd, m[1] as int, m[2] as int);
      case _Cmd.write:
        if (childGone || requestedGrace != null || shutdown != null) {
          config.events.send([_Msg.written, m[1], false]);
        } else {
          writing = m[2] as Uint8List;
          writeId = m[1] as int;
          writeOffset = 0;
        }
    }
  });
  config.events.send([_Msg.ready, pid, commands.sendPort]);
  try {
    while (true) {
      reap();
      if (requestedGrace != null || childGone) {
        settleWrite(false);
        startShutdown(requestedGrace ?? const Duration(seconds: 2));
      }
      if (shutdownDone) {
        await shutdown;
        if (shutdownError != null) throw shutdownError!;
        // Every owned writer is now gone. Drain only the finite kernel tail,
        // even if the consumer is paused; memory is window + OS PTY capacity.
        // Keep reading the kernel tail (FIONREAD is only a momentary view
        // and misses bytes still moving through the line discipline). With
        // owned writers gone this is finite. A detached writer is outside our
        // ownership; impose an explicit cap rather than let it prolong close
        // or grow memory without bound. Overflow is reported, never silent.
        var tailBudget = 1024 * 1024;
        while (tailBudget > 0) {
          final n = tina_pty_read(fd, buffer, math.min(tailBudget, 65536));
          if (n <= 0) break;
          tailBudget -= n;
          config.events
              .send([_Msg.output, Uint8List.fromList(buffer.asTypedList(n))]);
        }
        if (tailBudget == 0) {
          throw StateError(
              'PTY final output exceeded 1 MiB after session shutdown; '
              'a detached process may still be writing');
        }
        // The supervisor may need one scheduling turn to relay the status.
        final deadline = Stopwatch()..start();
        while (!childGone && deadline.elapsed < const Duration(seconds: 1)) {
          reap();
          if (!childGone)
            await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        if (rawStatus >= 0)
          code = rawStatus & 0x7f == 0
              ? (rawStatus >> 8) & 0xff
              : 128 + (rawStatus & 0x7f);
        break;
      }
      if (writing != null) {
        final bytes = writing!;
        final remaining = bytes.length - writeOffset;
        scratch
            .asTypedList(remaining)
            .setRange(0, remaining, bytes, writeOffset);
        final n = tina_pty_write(fd, scratch, remaining);
        if (n > 0) {
          writeOffset += n;
          if (writeOffset == bytes.length) settleWrite(true);
        } else if (n < 0) {
          settleWrite(false);
        }
      }
      if (credit > 0 && tina_pty_poll(fd, 0) > 0) {
        final n = tina_pty_read(fd, buffer, math.min(credit, 65536));
        if (n > 0) {
          credit -= n;
          config.events
              .send([_Msg.output, Uint8List.fromList(buffer.asTypedList(n))]);
        }
      }
      // Always yield, including while output is saturated or a child exited.
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  } catch (error) {
    failure = '$error';
    // Best effort after an unexpected error, but still await it before freeing
    // the transport. An enumeration failure is surfaced, never silent success.
    try {
      await _nativeSession(pid).terminate(grace: Duration.zero);
    } catch (cleanupError) {
      failure = '$failure; cleanup: $cleanupError';
    }
  } finally {
    if (shutdown != null) await shutdown;
    settleWrite(false);
    commands.close();
    tina_pty_close(fd);
    tina_pty_close(statusFd);
    malloc.free(buffer);
    malloc.free(scratch);
    malloc.free(status);
    config.events.send([_Msg.finished, code, failure]);
  }
}
