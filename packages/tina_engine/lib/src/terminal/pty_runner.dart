/// Headless PTY backend (Phase 1 of the interactive shell panel plan,
/// `docs/features/terminal_panel_plan.md`).
///
/// [PtyRunner] spawns a child on a pseudo-terminal; the returned
/// [PtyConnection] exposes its output as a broadcast byte stream, accepts
/// writes (bounded, with backpressure), resize, and an awaited idempotent
/// close that terminates the whole foreground job tree.
///
/// Design rules that matter:
///
/// - **No raw blocking I/O on the caller's isolate.** All read/poll/waitpid
///   work happens on a dedicated worker isolate with an explicit wakeup
///   (port send) and shutdown handshake.
/// - **The whole fork-to-exec child path is native.** After fork the child
///   only uses async-signal-safe calls until exec — see
///   `native/src/pty_shim.c`. Dart prepares executable, argv, environment,
///   and every allocation before the call.
/// - **Bounded queues, backpressure, no silent drops.** Writes queue up to
///   [PtyRunner.maxQueuedWrites] bytes; past that [PtyConnection.write]
///   awaits. Output chunks are streamed out as fast as the consumer takes
///   them; the worker holds at most one read chunk in flight per poll.
/// - **Close is awaited, idempotent, and ordered:** terminate the job tree
///   (SIGTERM → bounded grace → SIGKILL), drain remaining PTY output, then
///   report the exit status. Child exit and end-of-draining are separate
///   events; the final output is always delivered before [PtyConnection.done]
///   completes.
/// - **Reaped exactly once:** only the worker waits on the child.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, FileSystemException, Platform;
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'pty_shim_bindings.dart';

/// Launch request for [PtyRunner.spawn].
class PtySpawnRequest {
  /// Resolved executable path (no PATH search happens in the shim).
  final String executable;

  /// Argument list; `argv[0]` conventionally repeats the program name.
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
  String toString() =>
      'PtyException($kind, errno=$errno): $message';
}

/// Whether this platform has a PTY backend. The engine as a whole stays
/// importable and usable everywhere; only [PtyRunner.spawn] is limited.
bool get ptySupported {
  if (!Platform.isLinux && !Platform.isMacOS) return false;
  try {
    return tina_shim_abi_version() == 1;
  } catch (_) {
    return false; // native asset missing/stale
  }
}

/// Spawns children on pseudo-terminals. One instance per app is enough; all
/// state lives in the returned [PtyConnection].
class PtyRunner {
  /// Upper bound on queued outbound bytes before [PtyConnection.write]
  /// applies backpressure.
  final int maxQueuedWrites;

  const PtyRunner({this.maxQueuedWrites = 256 * 1024});

  /// Spawn [request] on a new PTY. Throws [PtyException] on a structured
  /// launch failure (bad executable, bad cwd) — the child never ran.
  Future<PtyConnection> spawn(PtySpawnRequest request) async {
    final worker = await _PtyWorker.spawn(request);
    return PtyConnection._(worker, maxQueuedWrites);
  }
}

/// A live child on a PTY.
class PtyConnection {
  final _PtyWorker _worker;
  final int _maxQueuedWrites;
  int _queued = 0;
  bool _closed = false;

  PtyConnection._(this._worker, this._maxQueuedWrites)
      : _exitCode = _worker.exitCode;

  /// Child process id.
  int get pid => _worker.pid;

  /// Raw output bytes from the PTY (stdout and stderr merged, as a terminal
  /// sees them). Broadcast: multiple listeners are fine. Complete after
  /// [close] finishes draining — always before [done].
  Stream<Uint8List> get output => _worker.output.stream;

  /// Completes when the child has exited **and** remaining output has been
  /// drained. Carries the child's exit code.
  Future<int> get done => _exitCode.future;
  final Completer<int> _exitCode;

  /// Whether the child has exited (regardless of drain state).
  bool get exited => _worker.exited;

  /// Queue [bytes] to the PTY. Applies backpressure once more than
  /// [PtyRunner.maxQueuedWrites] bytes are queued: the returned future
  /// completes only when the data (or enough of the queue) has been written.
  /// Short writes, EINTR and EAGAIN are handled by the worker; bytes are
  /// never dropped. Returns false if the connection is already closed.
  Future<bool> write(List<int> bytes) async {
    if (_closed || _worker.finalized) return false;
    final chunk = Uint8List.fromList(bytes);
    _queued += chunk.length;
    _worker.enqueueWrite(chunk);
    // Backpressure: wait until the queue is back under the bound.
    while (_queued > _maxQueuedWrites && !_closed) {
      final drained = await _worker.writtenBytes.first;
      _queued -= drained;
    }
    return true;
  }

  /// Resize the PTY window. Errors (already closed) are swallowed: a resize
  /// racing a close is not a failure worth surfacing.
  void resize(int rows, int cols) => _worker.resize(rows, cols);

  /// Terminate the child's job tree and close the connection.
  ///
  /// Idempotent: later calls return the same [done] future. Order of
  /// operations: SIGTERM to the tree, bounded [grace] wait, SIGKILL to
  /// survivors, drain remaining PTY output, complete [done]. Output delivered
  /// before the kill is preserved.
  Future<int> close({
    Duration grace = const Duration(seconds: 2),
  }) async {
    if (_closed) return _exitCode.future;
    _closed = true;
    try {
      await _worker.terminate(grace: grace);
    } on TimeoutException {
      // The worker missed the terminate command. done may still complete on
      // its own; if not, the caller has waited grace + 1s already.
    }
    final code = await _exitCode.future.timeout(const Duration(seconds: 2),
        onTimeout: () {
        return -1;
    });
    return code;
  }
}

// ---------------------------------------------------------------------------
// Worker isolate: owns all blocking native calls.
// ---------------------------------------------------------------------------

/// Messages main → worker.
enum _Cmd {
  /// One-time: attach the event port (payload: SendPort).
  _attach,

  /// Write these bytes; then report `_Msg.written`.
  write,

  /// Resize the window.
  resize,

  /// Kill tree + drain + reap; then report `_Msg.exit`. Terminal for worker.
  terminate,
}

/// Messages worker → main.
enum _Msg {
  /// Output bytes from the PTY.
  output,

  /// N bytes were written (backpressure accounting).
  written,

  /// The child exited with this wait status (decoded before sending).
  exited,

  /// The terminate handshake completed.
  terminated,

  /// The worker has finalized the terminal state: the PTY is closed and no
  /// further writes can be accepted. Output and done complete on the main
  /// side when this arrives.
  finalized,

  /// An error the caller should see (e.g. write after close). Fatal for the
  /// connection.
  error,
}

class _SpawnConfig {
  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String> environment;
  final int rows;
  final int cols;

  /// Port the worker sends output/exit events to. Created (and listened on)
  /// before [Isolate.spawn], so no event can race the handshake and be
  /// dropped: a fast-exiting child still delivers its status.
  final SendPort events;

  /// Handshake port: worker sends the child pid, then its command port.
  final SendPort toMain;

  _SpawnConfig(this.executable, this.arguments, this.workingDirectory,
      this.environment, this.rows, this.cols, this.events, this.toMain);
}

class _PtyWorker {
  late final int pid;
  late final SendPort _toWorker;
  Isolate? _iso;
  final bool Function() _exitedCleanly;
  final StreamController<Uint8List> output;
  final Completer<int> exitCode = Completer<int>();
  final _writtenBytes = StreamController<int>.broadcast();
  Stream<int> get writtenBytes => _writtenBytes.stream;
  bool exited = false;
  bool _terminated = false;

  /// Set when the worker reports the terminal state is final: output is
  /// completed and writes are refused at the source.
  bool finalized = false;

  /// Main side's end of the worker event channel. Kept open for the life of
  /// the connection so late worker messages are never dropped.
  final ReceivePort _eventsPort;

  /// Main side's end of the isolate-death signal. Closed with the events
  /// port in [disposePorts]; never leaked on any path.
  ReceivePort? _workerDone;

  /// Release the main-side ports. Called from [terminate] after the ack.
  void disposePorts() {
    _eventsPort.close();
    _workerDone?.close();
  }

  static Future<_PtyWorker> spawn(PtySpawnRequest req) async {
    final ready = ReceivePort();
    final events = ReceivePort();
    // Worker-death signal: fires when _workerMain returns (clean shutdown)
    // or the isolate is killed. terminate() awaits it as the authoritative
    // completion signal.
    final workerDone = ReceivePort();
    var exitedCleanlyFlag = false;
    var doneClosed = false;
    // Every port created here is closed on EVERY path — success and every
    // failure — or the main isolate keeps a live ReceivePort alive forever
    // (a leaked port keeps the isolate from exiting: the review probe hung
    // for 8s on a spawn/close sequence).
    void closeAllPorts() {
      ready.close();
      events.close();
      if (!doneClosed) {
        doneClosed = true;
        workerDone.close();
      }
    }

    workerDone.listen((_) => exitedCleanlyFlag = true);
    var exitedCleanly = false;
    final worker = _PtyWorker._(events, () => exitedCleanlyFlag || exitedCleanly);
    final config = _SpawnConfig(
        req.executable,
        req.arguments,
        req.workingDirectory,
        req.environment,
        req.rows,
        req.cols,
        events.sendPort,
        ready.sendPort);
    // Listen before the isolate exists: every event the worker ever sends
    // has a live receiver. A child that exits before the handshake still
    // reports its status.
    events.listen(worker._onEvent);
    // Single subscription, routed by a small state machine: a ReceivePort's
    // stream allows one listener ever, so no `await ready.first` twice.
    final toWorker = Completer<SendPort>();
    final pid = Completer<int>();
    var gotPid = false;
    late final StreamSubscription<dynamic> sub;
    sub = ready.listen((msg) {
      if (!gotPid) {
        gotPid = true;
        if (msg is _SpawnFailure) {
          ready.close();
          // Complete only via pid: spawn() awaits pid.future first and
          // surfaces the PtyException. toWorker's future is never awaited
          // on this path, so erroring it would go unobserved.
          pid.completeError(PtyException(msg.kind, msg.errno, msg.message));
          return;
        }
        pid.complete(msg as int);
        return;
      }
      // Second message: the worker's command port.
      sub.cancel();
      ready.close();
      toWorker.complete(msg as SendPort);
    });
    Isolate? iso;
    try {
      iso = await Isolate.spawn(_workerMain, config, onExit: workerDone.sendPort);
      final childPid = await pid.future;
      final workerPort = await toWorker.future;
      worker._setLink(childPid, workerPort);
      worker._iso = iso;
      worker._workerDone = workerDone;
      return worker;
    } catch (e) {
      // Spawn handshake failed: the isolate may still be starting, dead, or
      // about to report. Kill it and close every port; rethrow so the
      // caller sees the PtyException.
      iso?.kill();
      closeAllPorts();
      rethrow;
    }
  }

  _PtyWorker._(this._eventsPort, this._exitedCleanly)
      : output = StreamController<Uint8List>.broadcast(sync: true) {
    // Never drop terminal bytes (plan requirement; review: a listener
    // attached 150ms after spawn lost ALL output of a short-lived command,
    // because a broadcast controller with no listener silently drops).
    // Output arriving before a consumer attaches is buffered (bounded by
    // [_maxStartupBufferBytes], oldest chunk released past the cap) and
    // flushed in order on the first listen. Once a listener exists, a
    // paused listener is handled by the stream itself (its subscription
    // queues events; nothing is dropped). Write-side flow control between
    // consumer and worker is the writtenBytes credit protocol (see
    // PtyConnection.write); output-side is this bounded buffer.
    output.onListen = _flushStartupBuffer;
  }

  /// Output bytes captured while no consumer was attached (or while the
  /// consumer was paused). Oldest first. Bounded.
  final List<Uint8List> _startupBuffer = <Uint8List>[];
  int _startupBufferedBytes = 0;
  static const int _maxStartupBufferBytes = 1 << 20; // 1 MiB

  void _flushStartupBuffer() {
    if (_startupBuffer.isEmpty) return;
    final chunks = List<Uint8List>.of(_startupBuffer);
    _startupBuffer.clear();
    _startupBufferedBytes = 0;
    for (final chunk in chunks) {
      output.add(chunk); // controller is broadcasting now: no drop
    }
  }

  /// Worker → main output entry point. Buffers when nobody is listening or
  /// the listener is paused; forwards otherwise. Never silently drops.
  void _onOutput(Uint8List chunk) {
    if (!output.hasListener) {
      _startupBuffer.add(chunk);
      _startupBufferedBytes += chunk.length;
      // Bounded: past the cap, release the OLDEST chunk. This is the one
      // place bytes can be lost, and only after 1 MiB of unconsumed
      // terminal output — a state a real consumer never reaches.
      while (_startupBufferedBytes > _maxStartupBufferBytes &&
          _startupBuffer.length > 1) {
        _startupBufferedBytes -= _startupBuffer.removeAt(0).length;
      }
      return;
    }
    output.add(chunk);
  }

  /// Fill in the identity discovered by the handshake.
  void _setLink(int pid, SendPort toWorker) {
    this.pid = pid;
    _toWorker = toWorker;
  }

  void _onEvent(dynamic msg) {
    final list = msg as List;
    switch (_Msg.values[list[0] as int]) {
      case _Msg.output:
        _onOutput(list[1] as Uint8List);
      case _Msg.written:
        _writtenBytes.add(list[1] as int);
      case _Msg.exited:
        exited = true;
            if (!exitCode.isCompleted) exitCode.complete(list[1] as int);
      case _Msg.terminated:
        break; // handshake closes on the terminate path
      case _Msg.finalized:
        finalized = true;
        // One consistent terminal state: complete output (all listeners
        // see done), and refuse later writes.
        unawaited(output.close());
        _writtenBytes.close();
      case _Msg.error:
        // Surface as output-adjacent error; the connection stays usable.
        output.addError(StateError(list[1] as String));
    }
  }


  Future<void> enqueueWrite(Uint8List bytes) async {
    // Synchronous path: hand straight to the worker.
    _toWorker.send([_Cmd.write.index, bytes]);
  }

  void resize(int rows, int cols) => _toWorker.send([_Cmd.resize.index, rows, cols]);

  Future<void> terminate({required Duration grace}) async {
    if (_terminated) return;
    _terminated = true;
    _toWorker.send([_Cmd.terminate.index, grace.inMilliseconds, null]);
    // The worker SIGTERMs the group, escalates to SIGKILL, then exits once
    // the status has been relayed: awaiting the isolate death is the real
    // completion signal (no ack round-trip that could race the loop).
    final iso = _iso;
    if (iso != null) {
      final deadline =
          DateTime.now().add(grace + const Duration(seconds: 2));
        var spins = 0;
      while (!_exitedCleanly() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        spins++;
        if (spins % 100 == 0) {
              }
      }
      if (!_exitedCleanly()) {
        // Worker stuck past its own bound: kill it. The child itself is
        // covered by _killTree and the registry fallback in dispose.
            iso.kill();
        // Give a just-returned worker a moment to deliver its final events
        // (the exit status races the kill): wait for either the status or
        // the on-exit signal, bounded.
        final sw = Stopwatch()..start();
        while (!_exitedCleanly() && sw.elapsedMilliseconds < 500) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
          }
      }
    // Give the worker's final messages (the exit status) one scheduling turn
    // to land on the events port before its ports are torn down. disposePorts
    // below closes the events port's receive end: anything still in flight
    // would be dropped.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    disposePorts();
    await output.close().timeout(const Duration(seconds: 1),
        onTimeout: () {});
    _writtenBytes.close();
    // Last-resort hygiene: the worker normally exits on its own after the
    // drain, but if it raced us or stalled, kill it so nothing lingers.
    _iso?.kill();
    // Close the events port only after the worker is really gone: closing
    // earlier would drop its in-flight exit status.
    disposePorts();
  }
}

class _SpawnFailure {
  final PtyErrorKind kind;
  final int errno;
  final String message;
  const _SpawnFailure(this.kind, this.errno, this.message);
}

/// Worker entry. Owns: the PTY fd, the child pid, and the read/poll/reap
/// loop. Nothing blocking ever runs on the caller's isolate.
Future<void> _workerMain(_SpawnConfig config) async {
  final toMain = config.toMain;
  final fromMain = ReceivePort();

  // Materialize every string BEFORE the native call: the shim's child path
  // must not allocate Dart objects.
  final req = malloc<TinaPtySpawnRequest>();
  final out = malloc<TinaPtySpawnResult>();
  Pointer<Uint8>? exeP;
  Pointer<Pointer<Uint8>>? argvP;
  Pointer<Pointer<Uint8>>? envP;
  Pointer<Uint8>? cwdP;
  try {
    exeP = _toCString(config.executable, malloc);
    final argvItems = [config.executable, ...config.arguments];
    argvP = buildCStringArray(argvItems, malloc);
    final envItems = <String>[];
    config.environment.forEach((k, v) => envItems.add('$k=$v'));
    // An empty environment is legal and must map to an empty argv-style
    // array (a single NULL), not a NULL pointer: execve(NULL) is EFAULT.
    envP = envItems.isEmpty
        ? buildCStringArray(const <String>[], malloc)
        : buildCStringArray(envItems, malloc);
    if (config.workingDirectory != null) {
      cwdP = _toCString(config.workingDirectory!, malloc);
    }
    req.ref.executable = exeP;
    req.ref.argv = argvP;
    req.ref.env = envP;
    req.ref.cwd = cwdP ?? nullptr;
    req.ref.rows = config.rows;
    req.ref.cols = config.cols;

    final rc = tina_pty_spawn(req, out);
    if (rc < 0) {
      toMain.send(_SpawnFailure(PtyErrorKind.spawn, -rc,
          'pty spawn failed: ${_errnoName(-rc)}'));
      fromMain.close();
      return;
    }
    if (out.ref.error != 0) {
      final errno = out.ref.error;
      toMain.send(_SpawnFailure(
          errno == ENOENT || errno == EACCES
              ? PtyErrorKind.executable
              : (errno == ENOTDIR
                  ? PtyErrorKind.workingDirectory
                  : PtyErrorKind.spawn),
          errno,
          errno == ENOTDIR || errno == ELOOP || errno == ENAMETOOLONG
              ? 'bad working directory: ${_errnoName(errno)}'
              : 'cannot execute ${config.executable}: ${_errnoName(errno)}'));
      fromMain.close();
      return;
    }
    final pid = out.ref.pid;
    final masterFd = out.ref.masterFd;
    final statusFd = out.ref.statusFd;
    toMain.send(pid);               // handshake 2: the child pid
    toMain.send(fromMain.sendPort); // handshake 3: here is the cmd port
    await _runLoop(config.events, toMain, fromMain, pid, masterFd, statusFd);
  } finally {
    // Free every allocation (worker side; the child either exec'd or exited).
    if (exeP != null) malloc.free(exeP);
    if (argvP != null) freeCStringArray(argvP, malloc);
    if (envP != null) freeCStringArray(envP, malloc);
    if (cwdP != null) malloc.free(cwdP);
    malloc.free(req);
    malloc.free(out);
  }
}

const int ENOENT = 2;
const int EACCES = 13;
const int EIO = 5;
const int EAGAIN = 11;
const int EBADF = 9;
const int ESRCH = 3;
const int ENOTDIR = 20;
const int ELOOP = 40;
const int ENAMETOOLONG = 36;

String _errnoName(int e) => switch (e) {
      ENOENT => 'ENOENT',
      EACCES => 'EACCES',
      EIO => 'EIO',
      EBADF => 'EBADF',
      ENOTDIR => 'ENOTDIR',
      ELOOP => 'ELOOP',
      ENAMETOOLONG => 'ENAMETOOLONG',
      _ => 'errno $e',
    };

Pointer<Uint8> _toCString(String s, Allocator alloc) {
  final units = const Utf8Encoder().convert(s);
  final p = alloc<Uint8>(units.length + 1);
  p.asTypedList(units.length + 1)
    ..setRange(0, units.length, units)
    ..[units.length] = 0;
  return p;
}

Future<void> _runLoop(SendPort eventsPort, SendPort toMain,
    ReceivePort fromMain, int pid, int fd, int statusFd) async {
  final buf = malloc<Uint8>(65536);
  var exitStatus = -1;
  var childGone = false;
  var terminating = false;
  final writeQueue = <Uint8List>[];

  var forcedExit = false;

  void finish() {
    // Exit status decoding, mirroring WIFEXITED/WEXITSTATUS/WIFSIGNALED:
    // low 7 bits hold the signal (0 = normal exit), then the code sits in
    // the high byte. A signal death is reported as 128 + signal.
    int code;
    if (exitStatus < 0) {
      code = -1;
    } else if (exitStatus & 0x7f == 0) {
      code = (exitStatus >> 8) & 0xff;
    } else {
      code = 128 + (exitStatus & 0x7f);
    }
    eventsPort.send([_Msg.exited.index, code]);
    eventsPort.send([_Msg.finalized.index, 0]);
    fromMain.close();
    // No live ports or pending work remain: the worker isolate ends here
    // and becomes collectible. All native resources (the fd) were released
    // just above, before finish() ran.
  }

  /// Scratch buffer the head chunk is copied into for each write attempt.
  /// Copy-per-attempt keeps the queue as plain Dart bytes (no lifetime
  /// juggling) at the cost of one memcpy per pass — writes are small.
  final Pointer<Uint8> scratch = malloc<Uint8>(65536);

  void pumpWrites() {
    while (writeQueue.isNotEmpty) {
      final chunk = writeQueue.first;
      final len = chunk.length > 65536 ? 65536 : chunk.length;
      scratch.asTypedList(len).setRange(0, len, chunk);
      final n = tina_pty_write(fd, scratch, len);
      if (n > 0) {
        if (n < chunk.length) {
          // Short write: keep the remainder at the queue head.
          writeQueue[0] = Uint8List.sublistView(chunk, n);
        } else {
          writeQueue.removeAt(0);
        }
        eventsPort.send([_Msg.written.index, n]);
        continue;
      }
      if (n == 0) return; // EAGAIN: try again on the next loop pass
      if (-n == EIO) {
        // Slave closed (child gone): drop the pending writes; nothing can
        // receive them anymore. Report as written so backpressure clears.
        eventsPort.send([_Msg.written.index, chunk.length]);
        writeQueue.removeAt(0);
        continue;
      }
      // Unexpected error: give up on this chunk but keep the loop alive.
      writeQueue.removeAt(0);
      eventsPort
          .send([_Msg.error.index, 'pty write failed: ${_errnoName(-n)}']);
      continue;
    }
  }

  fromMain.listen((msg) {
    final list = msg as List;
    switch (_Cmd.values[list[0] as int]) {
      case _Cmd._attach:
        break; // handled above
      case _Cmd.write:
        writeQueue.add(list[1] as Uint8List);
        pumpWrites();
      case _Cmd.resize:
        tina_pty_resize(fd, list[1] as int, list[2] as int);
      case _Cmd.terminate:
        terminating = true;
        if (list[2] != null) (list[2] as SendPort).send(0);
            unawaited(() async {
                await _killTree(pid, list[1] as int)
              .timeout(const Duration(seconds: 3));
                // The kill tree has fully escalated (SIGTERM, grace, SIGKILL). If
          // the exit status still hasn't been relayed by now, force the
          // drain: the poll loop below would otherwise wait on a PTY whose
          // read side can stay open (e.g. the master fd held by the main
          // process while children linger briefly).
          forcedExit = true;
              }());
    }
  });

  // Reaping goes through the spawn's status pipe (the shim's supervisor
  // waits on the real child and relays the raw wait status): the VM's
  // wait(-1)-style child reaper can't make this fail with ECHILD, because
  // the child is a grandchild this process never waits on.
  bool reap() {
    if (childGone) return false;
    final st = malloc<Int32>();
    final wr = tina_pty_reap(statusFd, st, 0);
    if (wr != 0) {
      // > 0: status relayed. < 0 (e.g. -EIO): the supervisor died without
      // writing — SIGKILL may have hit the supervisor itself. Either way the
      // report channel is closed for good; treat the child as unrecoverable
      // and carry a best-effort status (-1 → reported as a signal death).
      childGone = true;
      exitStatus = wr > 0 ? st.value : -1;
    }
    malloc.free(st);
    return childGone;
  }

  // Main loop: poll the PTY, read output, pump writes, reap the child.
  while (true) {
    if (reap()) continue; // reaped: take the drain pass immediately

    pumpWrites();

    reap();

    if (forcedExit) break; // close out below, without touching the PTY

    if (childGone && writeQueue.isEmpty) {
      // Drain: read until EOF/EIO so the last output gets delivered before
      // the exit status.
      final n = tina_pty_read(fd, buf, 65536);
      if (n > 0) {
        eventsPort.send([
          _Msg.output.index,
          Uint8List.fromList(buf.asTypedList(n)),
        ]);
        continue;
      }
      if (n < 0) {
        // Drain genuinely ended (EIO is the normal end-of-pty signal once
        // the slave has no more readers).
        tina_pty_close(fd);
        tina_pty_close(statusFd);
        malloc.free(buf);
        malloc.free(scratch);
        finish();
        return;
      }
      // Would block: a descendant may still hold the slave open for a long
      // time (e.g. `sleep 300 &`). This branch MUST yield, or the loop
      // starves the isolate and terminate/timers are never processed — a
      // bounded grace would then never fire (regression: a 50ms grace took
      // 4.6s and was answered by the main isolate killing the worker).
      await Future<void>.delayed(const Duration(milliseconds: 5));
      continue;
    }

    // Yield to the event loop so control messages (write/resize/terminate)
    // are processed between poll cycles. No native call here blocks: a
    // blocking reap would freeze this isolate, stalling the terminate ack
    // and the whole shutdown sequence until the child happens to die.
    await Future<void>.delayed(
        terminating ? const Duration(milliseconds: 50) : Duration.zero);
    final pollRc = tina_pty_poll(fd, terminating ? 0 : 50);
    if (pollRc > 0) {
      // A poll hit may have more than one buffer queued: drain greedily (up
      // to a few reads per pass) so a fast producer isn't throttled to one
      // 64KB read per 50ms poll cycle.
      for (var drain = 0; drain < 8; drain++) {
        final n = tina_pty_read(fd, buf, 65536);
        if (n > 0) {
          eventsPort.send([
            _Msg.output.index,
            Uint8List.fromList(buf.asTypedList(n)),
          ]);
          continue; // buffer may hold more
        }
        if (n == 0) {
          // Readiness raced a refilled buffer; poll again next pass.
        }
        // n < 0 (EIO/EOF) or n == 0 dry: the top-of-loop pass decides.
        break;
      }
    }
    if (terminating && !childGone) {
      // _killTree escalates on its own schedule; just keep the loop turning
      // so output keeps flowing during the grace period.
    }
  }

  // Forced shutdown: _killTree has done its worst (SIGTERM, grace, SIGKILL).
  // A grandchild can hold the slave open forever, so close out
  // unconditionally rather than wait for an EOF that may never come: the
  // status is relayed (or forfeited) and lingering output is dropped.
  tina_pty_close(fd);
  tina_pty_close(statusFd);
  malloc.free(buf);
  malloc.free(scratch);
  finish();
}

/// Terminate the child's whole process tree: SIGTERM to every owned
/// process, bounded grace, then SIGKILL to every survivor.
///
/// The shim runs setsid() in the child, so the child is a session leader
/// and every process it spawns — foreground jobs, background jobs, job
/// control sub groups (`set -m`) — stays inside that session unless it
/// deliberately detaches with a setsid of its own (the plan puts those
/// outside terminal ownership). The owned set is therefore enumerated from
/// /proc as "all members of the child's session".
///
/// WHY NOT ONE GROUP SIGNAL: a job-control shell puts background jobs into
/// their own process groups, so `kill(-childpid, sig)` never reaches them.
/// WHY NOT THE SHELL PID: the shell usually exits first, leaving
/// descendants fully alive; probing only the pid skips the escalation
/// entirely (the round-1 leak). Probing each owned process by pid is the
/// only check that matches what must actually die.
///
/// Probes are `kill(pid, 0)`-equivalent checks through the shim — they
/// never reap, so the main loop stays the single source of the exit status.
Future<void> _killTree(int pid, int graceMs) async {
  // Session id of the owned tree: the child's own session (it is the
  // leader). Falls back to the pid if the child exited before we looked —
  // then the session is already gone and every probe below comes up empty.
  final sid = _sessionIdOf(pid) ?? pid;

  bool survivorsLeft() => _sessionMembers(sid).isNotEmpty;

  void signalOwned(int sig) {
    for (final member in _sessionMembers(sid)) {
      // Negative pid = the member's group too, in case it spawned children
      // of its own since the listing.
      tina_pty_kill(-member, sig);
    }
  }

  signalOwned(15); // SIGTERM to every owned process group
  const pollMs = 20;
  var waited = 0;
  while (waited < graceMs) {
    if (!survivorsLeft()) return; // whole tree gone: nothing to escalate to
    await Future<void>.delayed(const Duration(milliseconds: pollMs));
    waited += pollMs;
  }
  if (survivorsLeft()) {
    signalOwned(9); // SIGKILL: cannot be caught or ignored
    // Give the kernel a bounded moment so a caller that inspects the tree
    // right after close() sees it empty. SIGKILL is not ignorable, so this
    // settles quickly; the cap only guards a pathological /proc stall.
    const settleMs = 20;
    var settled = 0;
    while (survivorsLeft() && settled < 1000) {
      await Future<void>.delayed(const Duration(milliseconds: settleMs));
      settled += settleMs;
    }
  }
}

/// All live members of [sid]'s session, from /proc's own bookkeeping.
/// Empty on platforms without procfs (the group signal still runs).
List<int> _sessionMembers(int sid) {
  final members = <int>[];
  try {
    for (final entry in Directory('/proc').listSync()) {
      final pid = int.tryParse(entry.path.split('/').last);
      if (pid == null) continue;
      if (_sessionIdOf(pid) == sid) members.add(pid);
    }
  } on FileSystemException {
    // procfs vanished or is unreadable: report what we have.
  }
  return members;
}

/// Session id of [pid] — field 5 of /proc/<pid>/stat (field 4 of the
/// entries after the comm field, which may contain spaces and parentheses,
/// hence the scan from the last ')'). Null when the process is gone.
int? _sessionIdOf(int pid) {
  String stat;
  try {
    stat = File('/proc/$pid/stat').readAsStringSync();
  } on FileSystemException {
    return null; // raced an exit, or no procfs
  }
  final close = stat.lastIndexOf(')');
  if (close < 0 || close + 2 >= stat.length) return null;
  final fields = stat.substring(close + 2).split(' ');
  if (fields.length < 4) return null;
  return int.tryParse(fields[3]);
}
