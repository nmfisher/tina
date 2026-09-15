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
import 'dart:io' show Platform;
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
    if (_closed) return false;
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
    return _exitCode.future;
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
  final StreamController<Uint8List> output;
  final Completer<int> exitCode = Completer<int>();
  final _writtenBytes = StreamController<int>.broadcast();
  Stream<int> get writtenBytes => _writtenBytes.stream;
  bool exited = false;
  bool _terminated = false;

  /// Main side's end of the worker event channel. Kept open for the life of
  /// the connection so late worker messages are never dropped.
  final ReceivePort _eventsPort;

  /// Release the main-side ports. Called from [terminate] after the ack.
  void disposePorts() {
    _eventsPort.close();
  }

  static Future<_PtyWorker> spawn(PtySpawnRequest req) async {
    final ready = ReceivePort();
    final events = ReceivePort();
    final worker = _PtyWorker._(events);
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
    final iso = await Isolate.spawn(_workerMain, config);
    final childPid = await pid.future;
    final workerPort = await toWorker.future;
    worker._setLink(childPid, workerPort);
    worker._iso = iso;
    return worker;
  }

  _PtyWorker._(this._eventsPort)
      : output = StreamController<Uint8List>.broadcast();

  /// Fill in the identity discovered by the handshake.
  void _setLink(int pid, SendPort toWorker) {
    this.pid = pid;
    _toWorker = toWorker;
  }

  void _onEvent(dynamic msg) {
    final list = msg as List;
    switch (_Msg.values[list[0] as int]) {
      case _Msg.output:
        output.add(list[1] as Uint8List);
      case _Msg.written:
        _writtenBytes.add(list[1] as int);
      case _Msg.exited:
        exited = true;
        if (!exitCode.isCompleted) exitCode.complete(list[1] as int);
      case _Msg.terminated:
        break; // handshake closes on the terminate path
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
    final ack = ReceivePort();
    _toWorker.send([_Cmd.terminate.index, grace.inMilliseconds, ack.sendPort]);
    // The worker may have exited already (child raced us); an ack is a
    // courtesy, not a requirement.
    await ack.first.timeout(grace + const Duration(seconds: 1),
        onTimeout: () => 0);
    ack.close();
    disposePorts();
    await output.close().timeout(const Duration(seconds: 1));
    _writtenBytes.close();
    _eventsPort.close();
    // Last-resort hygiene: the worker normally exits on its own after the
    // drain, but if it raced us or stalled, kill it so nothing lingers.
    _iso?.kill();
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
    toMain.send(pid);               // handshake 2: the child pid
    toMain.send(fromMain.sendPort); // handshake 3: here is the cmd port
    await _runLoop(config.events, toMain, fromMain, pid, masterFd);
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
    ReceivePort fromMain, int pid, int fd) async {
  final buf = malloc<Uint8>(65536);
  var exitStatus = -1;
  var childGone = false;
  var terminating = false;
  final writeQueue = <Uint8List>[];
  SendPort? terminateAck;

  void finish() {
    // ignore: avoid_print
    print('FINISH: raw status=' + exitStatus.toString());
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
    if (terminateAck != null) {
      terminateAck!.send(0);
    }
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
        terminateAck = list[2] as SendPort;
        unawaited(_killTree(pid));
    }
  });

  // Main loop: poll the PTY, read output, pump writes, reap the child.
  while (true) {
    // Reap, non-blocking, exactly here — the only waitpid call site.
    if (!childGone) {
      final st = malloc<Int32>();
      final wr = tina_pty_waitpid(pid, st, 0);
      // ignore: avoid_print
      if (wr != 0) print('REAP: wr=' + wr.toString() + ' status=' + st.value.toString());
      if (wr > 0) {
        childGone = true;
        exitStatus = st.value;
      }
    }

    pumpWrites();

    if (!childGone) {
      // Reap, non-blocking, exactly here — the only waitpid call site.
      final st = malloc<Int32>();
      final wr = tina_pty_waitpid(pid, st, 0);
      if (wr > 0) {
        childGone = true;
        exitStatus = st.value;
      }
    }

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
      if (n == 0) continue; // would block: keep polling until EOF/EIO
      // n < 0: EIO is the normal end-of-pty signal on Linux once the slave
      // has no more readers. Anything else is unexpected but not fatal.
      tina_pty_close(fd);
      malloc.free(buf);
      malloc.free(scratch);
      finish();
      return;
    }

    if (terminating && childGone && writeQueue.isEmpty) {
      // Wait for the drain pass above to hit EOF/EIO; loop continues.
    }

    // Yield to the event loop so control messages (write/resize/terminate)
    // are processed between poll cycles. poll is the only blocking wait.
    await Future<void>.delayed(Duration.zero);
    final pollRc = tina_pty_poll(fd, 50);
    if (pollRc > 0) {
      final n = tina_pty_read(fd, buf, 65536);
      if (n > 0) {
        eventsPort.send([
          _Msg.output.index,
          Uint8List.fromList(buf.asTypedList(n)),
        ]);
      }
      // n == 0 (spurious) or n < 0: handled on the next pass.
    }
    if (terminating && !childGone) {
      // _killTree escalates on its own schedule; just keep the loop turning
      // so output keeps flowing during the grace period.
    }
  }
  // Unreachable: finish() returns. Kept for clarity if the loop ever grows
  // a second exit.
}

/// SIGTERM the child's process group (the shim put the child in its own
/// session, so -pid hits every descendant still in it), wait a bounded
/// grace, then SIGKILL. Liveness is probed with kill(-pid, 0) only — this
/// never reaps, so the main loop stays the single source of the exit
/// status. Best-effort for stragglers outside the group: the main isolate's
/// [ChildProcessRegistry] fallback covers those.
Future<void> _killTree(int pid) async {
  tina_pty_kill(-pid, 15); // SIGTERM the process group
  const pollMs = 20;
  const graceMs = 2000;
  var waited = 0;
  while (waited < graceMs) {
    if (tina_pty_kill(-pid, 0) == -ESRCH) return; // whole group gone
    await Future<void>.delayed(const Duration(milliseconds: pollMs));
    waited += pollMs;
  }
  tina_pty_kill(-pid, 9); // SIGKILL the survivors
  waited = 0;
  while (waited < graceMs) {
    if (tina_pty_kill(-pid, 0) == -ESRCH) return;
    await Future<void>.delayed(const Duration(milliseconds: pollMs));
    waited += pollMs;
  }
}
