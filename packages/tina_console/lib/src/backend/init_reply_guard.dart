import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';
import 'package:meta/meta.dart';

/// Bounds the wait for terminal capability replies around notcurses init.
///
/// notcurses sends ~2.8 KB of terminal queries at init (OSC 4 palette,
/// OSC 10/11, DECRPM, DA1) and then waits for the **DA1** reply before it
/// will return: `inputlayer_get_responses` blocks on a condition variable
/// with no deadline (notcurses 3.0.17, src/lib/in.c). A terminal that
/// answers none of them therefore hangs init forever — which is what
/// happens inside a *detached* tmux session, where the server has no
/// attached client to answer the OSC queries (tin-r2vd).
///
/// No notcurses option skips the queries or bounds that wait
/// (`NCOPTION_DRAIN_INPUT` means "never read input", not "don't wait for
/// replies"), and the library is statically linked, so the wait has to be
/// broken from the caller's side.
///
/// How this guard does it:
///
/// 1. Before init, ask the terminal a question only an attached client
///    answers (OSC 10/11), with echo off so the reply is not splattered
///    over the user's screen.
/// 2. If a reply arrives, stand down: init gets its own replies and the
///    normal path is unchanged.
/// 3. If nothing arrives within [probeTimeout] the terminal is mute: put a
///    pty this process owns onto fd 0, satisfy DA1 ourselves, run init —
///    it completes immediately on terminfo defaults — then put the real
///    stdin back. That is the "proceed with defaults after a bounded wait"
///    path. The fallback DA1 declares a plain VT220 with ANSI colour and
///    nothing else, so no palette, sixel or kitty support is implied.
///
/// fd 0 is NOT restored after init — it stays on the detour pty for the
/// life of the session. notcurses' input thread enters `ppoll(fd 0)` while
/// fd 0 is the detour slave, and poll binds the file description at
/// syscall entry, so that thread waits on the detour slave forever no
/// matter what fd 0 points at afterwards. Swapping fd 0 back to the real
/// stdin splits the input path — the thread *reads* the real tty while its
/// poll still waits on the detour — and every keystroke is lost (the
/// DEAD-KEYBOARD of [tool/mute_pty_driver.py]; proven with
/// [tool/mute_diag_probe.dart] under [tool/syscall_diag_driver.py], which
/// decodes the thread's pollfd out of process memory). Instead the real
/// stdin keeps flowing into the detour master via [StdinBridge], so poll
/// target and read target agree on one pty. The owner of the guard
/// (NotcursesBackend) must call [TerminalReplyGuard.shutdown] before it
/// destroys the notcurses context; that stops the bridge, gives the real
/// terminal its original mode back and tears the detour pty down.
class TerminalReplyGuard {
  /// The guard and its [StdinBridge] must share ONE os layer: the bridge
  /// copies bytes between the very fds [ReplyGuardOs.installDetour] opened,
  /// so a second instance (whose master/source are forever −1) would make
  /// the copy loop a silent no-op — the keyboard stays dead with no error
  /// anywhere. The redirect guarantees that even default construction
  /// builds exactly one.
  TerminalReplyGuard({ReplyGuardOs? os})
      : this._shared(os ?? ReplyGuardOs.posix());

  TerminalReplyGuard._shared(ReplyGuardOs os)
      : _os = os,
        _bridge = StdinBridge(os);

  final ReplyGuardOs _os;
  final StdinBridge _bridge;

  /// Whether the guard and its bridge operate on the same os instance.
  /// Regression seam for the two-instance constructor bug.
  @visibleForTesting
  bool get sharesOsLayer => identical(_os, _bridge._os);

  /// The query whose silence proves the terminal cannot answer: OSC 10
  /// (default foreground) and OSC 11 (default background). Deliberately
  /// not DA1 — a lone DA1 arriving before notcurses' own queries would
  /// complete its init wait before the palette replies landed, silently
  /// losing colour detection for every attached user.
  static const String probeQuery = '\x1b]10;?\x1b\\\x1b]11;?\x1b\\';

  /// The reply that releases notcurses' init wait: DA1, VT220 class with
  /// the ANSI-colour attribute. Attribute 4 would claim sixel and 28
  /// rectangular edits; 22 claims neither.
  static const String fallbackReply = '\x1b[?62;22c';

  /// How long to wait for the probe reply before deciding the terminal is
  /// mute. Generous for a slow SSH round trip; an attached terminal
  /// answers in a millisecond or two.
  static const int probeTimeoutMs = 400;

  /// Upper bound on probe-reply bytes to consume before echo comes back.
  static const int drainLimit = 4096;

  bool _armed = false;
  bool _bridgeStarted = false;
  bool _sessionEnded = false;

  /// The stdin bridge owned by this guard. Exposed for tests that drive
  /// pump ticks manually instead of waiting on the real timer.
  @visibleForTesting
  StdinBridge get bridge => _bridge;

  /// Whether [restore] started the stdin bridge and [shutdown] has not yet
  /// cancelled it.
  @visibleForTesting
  bool get bridgeRunning => _bridgeStarted && _bridge.running;

  /// Whether [restore] has anything to put back.
  bool get armed => _armed;

  /// Probe the terminal and, if it is mute, install the fd-0 pty detour.
  ///
  /// Call immediately before creating the notcurses context. Returns true
  /// when the detour is armed — the caller must then call [restore] once
  /// init returns, on success and on failure alike. Never throws: on any
  /// error the guard stands down and startup proceeds as it would have
  /// without it.
  bool prepare() {
    try {
      return _prepare();
    } catch (_) {
      _os.abandon();
      _armed = false;
      return false;
    }
  }

  bool _prepare() {
    // Without a terminal at both ends there is nothing to probe; notcurses
    // reports the problem itself and that path is already handled.
    if (!_os.isTerminal(0) || !_os.isTerminal(1)) return false;

    // Echo off while the reply is in flight, or the line discipline writes
    // it back to the user's screen as garbage. Restored on every path.
    final savedMode = _os.enterRawMode(0);
    try {
      if (savedMode == null) return false;
      _os.write(1, probeQuery);
      if (_os.pollReadable(0, probeTimeoutMs)) {
        // Consume the reply so it is neither echoed after raw mode comes
        // off nor mistaken for a keystroke later. notcurses re-queries
        // everything itself, so losing it costs nothing.
        _os.drain(0, drainLimit);
        return false;
      }
    } finally {
      _os.restoreMode(0, savedMode);
    }

    // Mute terminal: satisfy DA1 ourselves so init cannot hang.
    final armed = _os.installDetour(fallbackReply);
    _armed = armed;
    return armed;
  }

  /// Adopt the detour pty as the session's input terminal. No-op unless
  /// [prepare] returned true. Call once notcurses init has returned.
  ///
  /// fd 0 deliberately STAYS on the detour slave (see the class comment:
  /// notcurses' input thread is wedged to it by an already-entered ppoll).
  /// This switches the real stdin — still held open by the OS layer — to
  /// raw + non-blocking, forwards window-size changes into the detour, and
  /// starts the stdin bridge copying real stdin into the detour master
  /// every [StdinBridge.tickMs]. Call [shutdown] when the notcurses
  /// context goes away.
  void finishInit() {
    if (!_armed) return;
    _armed = false;
    try {
      _os.beginBridgedSession();
      // Start the copy loop only when there is actually a master to feed:
      // on POSIX this is the pty notcurses reads for the whole session.
      if (_os.bridgeMasterFd >= 0) {
        _bridge.start();
        _bridgeStarted = true;
      }
    } catch (_) {
      // The detour is all fd 0 has now; if wiring the bridge fails the
      // keyboard is lost either way and there is nothing the caller could
      // do about it from here.
    }
  }

  /// Stop the stdin bridge and tear the detour down: real terminal mode
  /// restored, detour master released. Safe to call more than once and from
  /// any state (never started / never armed / already shut down): every path
  /// is a no-op then. Must be called by whoever owns the guard once the
  /// notcurses context is being torn down — before it, so the pump thread
  /// never reads from a pty whose master closed mid-drain.
  void shutdown() {
    _bridgeStarted = false;
    try {
      _bridge.stop();
    } catch (_) {
      // The bridge is best-effort; a failure to stop cleanly must not
      // propagate into teardown.
    }
    if (_sessionEnded) return;
    _sessionEnded = true;
    try {
      _os.endBridgedSession();
    } catch (_) {
      // Same here: teardown must run to completion even if an fd close or
      // mode restore fails part-way.
    }
  }
}

/// Copies the real stdin (held open by the OS layer as the bridge source)
/// into the detour pty master, so notcurses keeps hearing the keyboard from
/// the pty its input thread is wedged to (see the [TerminalReplyGuard]
/// class comment). Reading fd 0 instead would be wrong twice over: fd 0 is
/// the detour slave — the bridge would compete with notcurses for it — and
/// the real tty would have no reader at all.
///
/// The copy runs as a periodic poll/read/write cycle on the Dart event loop
/// rather than on a dedicated thread: it must not compete with notcurses'
/// own input thread for the pty, and a 10 ms cadence is far below what a
/// human can perceive (~50 ms). Every tick is best-effort — read errors,
/// write errors and a vanished master all leave the loop running until
/// [stop]; only the timer's own cancellation ends it.
class StdinBridge {
  StdinBridge(this._os);

  final ReplyGuardOs _os;

  /// How often the pump wakes up to move bytes. Small enough that typing
  /// never feels laggy (a keypress waits at most one tick), large enough
  /// that an idle session costs a single no-op syscall per tick.
  static const int tickMs = 10;

  /// Per-read upper bound. A fast paste can deliver far more than this per
  /// tick; [_maxChunksPerTick] caps how many chunks are moved per wake-up
  /// so a firehose input cannot starve the rest of the event loop.
  static const int chunkBytes = 4096;

  /// Read chunks drained per tick before leaving the rest for the next one.
  static const int maxChunksPerTick = 16;

  /// Give up on buffered bytes beyond this size. The master's buffer only
  /// backs up if notcurses stops reading for seconds; past that point the
  /// least-bad outcome is dropping oldest keystrokes rather than growing
  /// the buffer unbounded or stalling the pump forever.
  static const int pendingDropLimit = 256 * 1024;

  Timer? _timer;
  Uint8List _pending = Uint8List(0);
  bool _ticking = false;
  bool _loggedError = false;

  /// Whether [start] has armed the periodic copy and [stop] has not yet
  /// cancelled it.
  @visibleForTesting
  bool get running => _timer != null;

  /// Bytes waiting to be written to the master after a short write, exposed
  /// for tests that drive the pump manually.
  @visibleForTesting
  int get pendingBytes => _pending.length;

  /// Begin copying stdin into the pty master every [tickMs]. Idempotent:
  /// calling it while already running keeps the existing timer.
  void start() {
    if (_timer != null) return;
    _timer =
        Timer.periodic(const Duration(milliseconds: tickMs), (_) => tick());
  }

  /// Cancel the periodic copy and drop anything buffered but not yet
  /// delivered. Idempotent.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _pending = Uint8List(0);
  }

  /// Copy [bytes] into the master exactly as a tick would, without reading
  /// stdin first. Test hook for driving short-write/retry behaviour
  /// deterministically; shares the buffering path with [tick].
  @visibleForTesting
  void feedBytes(Uint8List bytes) {
    if (_os.bridgeMasterFd < 0 || bytes.isEmpty) return;
    var written = 0;
    while (written < bytes.length) {
      final n =
          _os.writeBytes(_os.bridgeMasterFd, Uint8List.sublistView(
              bytes, written));
      if (n <= 0) {
        _buffer(Uint8List.sublistView(bytes, written));
        return;
      }
      written += n;
    }
  }

  /// One copy cycle: retry undelivered bytes, then move up to
  /// [maxChunksPerTick] fresh chunks from the real stdin into the master.
  /// Production invocations come from the [Timer.periodic] armed by [start];
  /// exposed so tests can step the pump deterministically instead of
  /// sleeping.
  @visibleForTesting
  void tick() {
    // Re-entrancy guard: a slow FFI call must not let two ticks interleave.
    if (_ticking) return;
    if (_os.bridgeMasterFd < 0) {
      // Master already released (teardown race or an abandoned detour):
      // there is nowhere to forward bytes, so do not even lift them out of
      // the kernel queue — dropping keystrokes here is silent by design,
      // the keyboard is gone regardless once the pty dies.
      return;
    }
    final source = _os.bridgeSourceFd;
    if (source < 0) {
      // No real stdin held behind the detour (never armed, or the session
      // already ended): same story as above, nowhere to pull bytes from.
      return;
    }
    _ticking = true;
    try {
      _flushPending();
      var chunks = 0;
      while (chunks < maxChunksPerTick) {
        final chunk = _os.readBytes(source, chunkBytes);
        if (chunk.isEmpty) break;
        chunks++;
        var written = 0;
        while (written < chunk.length) {
          final n = _os.writeBytes(_os.bridgeMasterFd,
              Uint8List.sublistView(chunk, written));
          if (n <= 0) {
            _buffer(Uint8List.sublistView(chunk, written));
            written = chunk.length;
          } else {
            written += n;
          }
        }
      }
    } catch (_) {
      // One logged line per bridge lifetime: the loop itself keeps going,
      // because the alternative is a dead keyboard with no trace.
      if (!_loggedError) {
        _loggedError = true;
        assert(() {
          stderr.writeln('stdin bridge: copy error, retrying next tick');
          return true;
        }());
      }
    } finally {
      _ticking = false;
    }
  }

  /// Retry whatever a previous tick could not push into the master yet.
  void _flushPending() {
    while (_pending.isNotEmpty) {
      final n = _os.writeBytes(_os.bridgeMasterFd, _pending);
      if (n <= 0) return; // still backed up; keep it for the next tick
      if (n >= _pending.length) {
        _pending = Uint8List(0);
      } else {
        _pending = Uint8List.fromList(
            Uint8List.sublistView(_pending, n));
      }
    }
  }

  /// Park undelivered bytes for later ticks, applying [pendingDropLimit].
  void _buffer(Uint8List extra) {
    if (_pending.isEmpty && extra.length > pendingDropLimit) {
      _pending = Uint8List.fromList(
          Uint8List.sublistView(extra, extra.length - pendingDropLimit));
      return;
    }
    final merged = Uint8List(_pending.length + extra.length)
      ..setAll(0, _pending)
      ..setAll(_pending.length, extra);
    if (merged.length > pendingDropLimit) {
      _pending = Uint8List.fromList(
          Uint8List.sublistView(merged, merged.length - pendingDropLimit));
    } else {
      _pending = merged;
    }
  }
}

/// The fd-level operations [TerminalReplyGuard] needs. The live
/// implementation is POSIX via FFI; tests substitute a recording fake.
abstract class ReplyGuardOs {
  /// True when [fd] refers to a terminal.
  bool isTerminal(int fd);

  /// Write [bytes] to [fd]. Best-effort: short writes are acceptable.
  void write(int fd, String bytes);

  /// True when [fd] became readable within [timeoutMs]. Must not consume:
  /// the data is left for whoever reads next.
  bool pollReadable(int fd, int timeoutMs);

  /// Read and discard up to [maxBytes] of pending input from [fd].
  void drain(int fd, int maxBytes);

  /// Put [fd] in raw mode (echo and line buffering off) so probe replies
  /// are neither echoed nor line-buffered. Returns opaque saved state for
  /// [restoreMode], or null when the mode could not be changed — in which
  /// case the probe is skipped rather than run with echo on.
  Object? enterRawMode(int fd);

  /// Restore the mode captured by [enterRawMode]. A null [saved] is a no-op.
  void restoreMode(int fd, Object? saved);

  /// Replace fd 0 with a pty slave this process owns, feed [reply] into it
  /// from the master side, and remember how to undo the swap. Returns
  /// false when the detour could not be installed.
  bool installDetour(String reply);

  /// Keep the detour as the session terminal: fd 0 stays on the pty slave,
  /// the real stdin stays held open by the OS layer and is switched to raw +
  /// non-blocking (with its original mode remembered for
  /// [endBridgedSession]), and window-size changes start flowing into the
  /// detour. After this the real stdin is only read via [bridgeSourceFd].
  void beginBridgedSession();

  /// End the session started by [beginBridgedSession]: restore the real
  /// terminal's original mode, close the held-open real stdin and release
  /// the detour master (which tears the pty — and with it notcurses' input
  /// thread — down). No-op when no session was begun.
  void endBridgedSession();

  /// The real stdin fd held open for the stdin bridge to read after
  /// [beginBridgedSession], or a negative value when there is none — no
  /// detour was armed, or the session has already ended. Ownership stays
  /// here; valid for reads until [endBridgedSession].
  int get bridgeSourceFd;

  /// The detour pty master the stdin bridge feeds for the life of the
  /// session, or a negative value when there is none — no detour was
  /// installed, or it has already been released. Valid for reads and writes
  /// until [releaseBridgeMaster]; ownership stays here.
  int get bridgeMasterFd;

  /// Close and forget the fd reported by [bridgeMasterFd]. Idempotent and
  /// safe when there is nothing to release.
  void releaseBridgeMaster();

  /// Read whatever is pending on [fd], up to [maxBytes]. Non-blocking:
  /// returns an empty list immediately when nothing has arrived (or the fd
  /// is gone) rather than waiting for input.
  Uint8List readBytes(int fd, int maxBytes);

  /// Best-effort write of [bytes] to [fd]; returns the number of bytes
  /// accepted, which may be fewer than [bytes.length] — or zero — when the
  /// fd is non-blocking and its buffer is momentarily full.
  int writeBytes(int fd, Uint8List bytes);

  /// Release resources held by a detour without touching fd 0. Called when
  /// the guard aborts between [installDetour] and [beginBridgedSession].
  void abandon();

  /// The live POSIX implementation.
  factory ReplyGuardOs.posix() = PosixReplyGuardOs;
}

class PosixReplyGuardOs implements ReplyGuardOs {
  int? _savedStdin;
  int? _master;

  /// The real terminal's termios as it was before [beginBridgedSession]
  /// switched it to raw, restored by [endBridgedSession]. Null when no
  /// session is active.
  ffi.Pointer<ffi.Uint8>? _sessionTermios;

  /// Forwards SIGWINCH from the real terminal into the detour pty while a
  /// bridged session runs, so notcurses' fd-0 size stays truthful.
  StreamSubscription<ProcessSignal>? _sigwinchSub;

  @override
  bool isTerminal(int fd) => _isatty(fd) == 1;

  @override
  void write(int fd, String bytes) {
    final data = Uint8List.fromList(bytes.codeUnits);
    final buf = _malloc(data.length);
    try {
      buf.asTypedList(data.length).setAll(0, data);
      _write(fd, buf, data.length);
    } finally {
      _free(buf);
    }
  }

  @override
  bool pollReadable(int fd, int timeoutMs) {
    // struct pollfd { int fd; short events; short revents; } — 8 bytes.
    final p = _malloc(8);
    try {
      p.cast<ffi.Int32>()[0] = fd;
      p.cast<ffi.Int16>()[2] = 0x0001; // POLLIN, at byte offset 4
      return _poll(p, 1, timeoutMs) > 0;
    } finally {
      _free(p);
    }
  }

  @override
  void drain(int fd, int maxBytes) {
    final buf = _malloc(4096);
    try {
      var remaining = maxBytes;
      while (remaining > 0) {
        final chunk = remaining < 4096 ? remaining : 4096;
        final n = _read(fd, buf, chunk);
        if (n <= 0) break;
        remaining -= n;
        if (n < chunk) break; // short read: the queue is empty
      }
    } finally {
      _free(buf);
    }
  }

  @override
  Object? enterRawMode(int fd) {
    final saved = _malloc(termiosBytes);
    try {
      if (_tcgetattr(fd, saved) != 0) return null;
      final raw = _malloc(termiosBytes);
      try {
        _memcpy(raw, saved, termiosBytes);
        _cfmakeraw(raw);
        if (_tcsetattr(fd, _tcsanow, raw) != 0) return null;
        return _SavedTermios(saved);
      } finally {
        _free(raw);
      }
    } catch (_) {
      _free(saved);
      return null;
    }
  }

  @override
  void restoreMode(int fd, Object? saved) {
    if (saved is! _SavedTermios) return;
    try {
      _tcsetattr(fd, _tcsanow, saved.bytes);
    } finally {
      _free(saved.bytes);
    }
  }

  @override
  bool installDetour(String reply) {
    final openpty = _openpty;
    if (openpty == null) return false;

    final saved = _dup(0);
    if (saved < 0) return false;

    final am = _malloc(4);
    final as = _malloc(4);
    final termios = _malloc(termiosBytes);
    var slave = -1;
    var master = -1;
    var swapped = false;
    try {
      if (openpty(am.cast<ffi.Int32>(), as.cast<ffi.Int32>(), ffi.nullptr,
              ffi.nullptr, ffi.nullptr) !=
          0) {
        return false;
      }
      master = am.cast<ffi.Int32>()[0];
      slave = as.cast<ffi.Int32>()[0];

      // A fresh pty slave is canonical with echo on: it would line-buffer
      // the reply and never deliver it. Make it raw.
      if (_tcgetattr(slave, termios) == 0) {
        _cfmakeraw(termios);
        _tcsetattr(slave, _tcsanow, termios);
      }

      // notcurses reads the terminal size from fd 0 at init; without this
      // the detour pty would carry the fresh-openpty default (0x0) and the
      // mute-terminal session would render into a zero-sized plane. fd 0 is
      // still the real terminal at this point.
      _copyWinsize(0, slave);

      if (_dup2(slave, 0) < 0) return false;
      swapped = true;
      _close(slave);

      write(master, reply);

      _savedStdin = saved;
      _master = master;
      return true;
    } catch (_) {
      // Roll back whatever got as far as being opened or swapped. fd 0 is
      // only touched when the swap had already happened, in which case
      // putting the saved stdin back is the only correct exit.
      if (swapped) {
        _dup2(saved, 0);
      }
      if (slave >= 0 && !swapped) _close(slave);
      if (master >= 0) _close(master);
      _savedStdin = null;
      _master = null;
      return false;
    } finally {
      _free(am);
      _free(as);
      _free(termios);
    }
  }

  @override
  void beginBridgedSession() {
    final saved = _savedStdin;
    if (saved == null || saved < 0) return;
    // Remember the terminal's current mode: the bridge needs raw for the
    // rest of the session, and the user deserves their cooked terminal back
    // when it ends.
    final snapshot = _malloc(termiosBytes);
    if (_tcgetattr(saved, snapshot) == 0) {
      _sessionTermios = snapshot;
    } else {
      _free(snapshot);
    }
    final raw = _malloc(termiosBytes);
    try {
      if (_tcgetattr(saved, raw) == 0) {
        _cfmakeraw(raw);
        _tcsetattr(saved, _tcsanow, raw);
      }
    } finally {
      _free(raw);
    }
    // Non-blocking, like notcurses expects its tty: the bridge's read loop
    // treats EAGAIN as "idle" and moves on.
    final flags = _fcntl(saved, _fGetFl, 0);
    if (flags >= 0) _fcntl(saved, _fSetFl, flags | _oNonblock);
    // Keep the detour pty sized like the real terminal, now and on every
    // resize: notcurses re-reads fd 0's size on SIGWINCH, and fd 0 is the
    // detour for the life of the session.
    final master = _master;
    if (master != null && master >= 0) {
      _copyWinsize(saved, master);
      _sigwinchSub = ProcessSignal.sigwinch.watch().listen((_) {
        final m = _master;
        final s = _savedStdin;
        if (m != null && m >= 0 && s != null && s >= 0) {
          _copyWinsize(s, m);
        }
      });
    }
  }

  @override
  void endBridgedSession() {
    _sigwinchSub?.cancel();
    _sigwinchSub = null;
    final saved = _savedStdin;
    _savedStdin = null;
    final tio = _sessionTermios;
    _sessionTermios = null;
    if (saved != null && saved >= 0) {
      if (tio != null) {
        _tcsetattr(saved, _tcsanow, tio);
        _free(tio);
      }
      _close(saved);
    }
    // Releasing the master tears the detour pty down; notcurses' input
    // thread, wedged to the slave since init, sees its poll go dead and
    // exits. Callers do this before destroying the notcurses context.
    releaseBridgeMaster();
  }

  @override
  int get bridgeSourceFd => _savedStdin ?? -1;

  @override
  int get bridgeMasterFd => _master ?? -1;

  @override
  void releaseBridgeMaster() {
    final master = _master;
    _master = null;
    if (master != null && master >= 0) _close(master);
  }

  @override
  Uint8List readBytes(int fd, int maxBytes) {
    final buf = _malloc(maxBytes);
    try {
      final n = _read(fd, buf, maxBytes);
      if (n <= 0) return Uint8List(0);
      // Copy out before the buffer is freed.
      return Uint8List.fromList(buf.asTypedList(n));
    } finally {
      _free(buf);
    }
  }

  @override
  int writeBytes(int fd, Uint8List bytes) {
    if (bytes.isEmpty) return 0;
    final buf = _malloc(bytes.length);
    try {
      buf.asTypedList(bytes.length).setAll(0, bytes);
      final n = _write(fd, buf, bytes.length);
      if (n < 0) return 0; // EAGAIN and friends: nothing accepted
      return n > bytes.length ? bytes.length : n;
    } finally {
      _free(buf);
    }
  }

  @override
  void abandon() {
    _savedStdin = null;
    releaseBridgeMaster();
  }

  // -- FFI plumbing -------------------------------------------------------

  /// Room for struct termios on linux/arm64, linux/x86_64 and macOS, with
  /// slack. tcgetattr writes at most the real size, so over-allocating is
  /// safe; the slack is never read back.
  static const int termiosBytes = 128;

  static const int _tcsanow = 0;
  static const int _fGetFl = 3;
  static const int _fSetFl = 4;
  static const int _oNonblock = 0x800;

  // Linux ioctl request values for the window-size copy (see _copyWinsize).
  static const int _tiocgwinsz = 0x5413;
  static const int _tiocswinsz = 0x5414;

  /// Copy the window size of [from] to [to] (either side of a pty pair
  /// works as [to]). Best-effort: a failure leaves the old size in place.
  void _copyWinsize(int from, int to) {
    final ws = _malloc(8); // struct winsize: four unsigned shorts
    try {
      if (_ioctl(from, _tiocgwinsz, ws.cast()) == 0) {
        _ioctl(to, _tiocswinsz, ws.cast());
      }
    } catch (_) {
      // Size forwarding is decoration; it must never disturb the session.
    } finally {
      _free(ws);
    }
  }

  static final ffi.DynamicLibrary _libc = ffi.DynamicLibrary.process();

  /// openpty: in libc since glibc 2.34, in libutil before that, in
  /// libSystem on macOS. Null when no candidate exports it, in which case
  /// the detour is unavailable and the guard stands down.
  static final ffi.DynamicLibrary? _openptyLib = _resolveOpenpty();

  static ffi.DynamicLibrary? _resolveOpenpty() {
    final candidates = <ffi.DynamicLibrary>[ffi.DynamicLibrary.process()];
    for (final name in const ['libutil.so.2', 'libutil.so']) {
      try {
        candidates.add(ffi.DynamicLibrary.open(name));
      } catch (_) {
        // Not present on this platform; later candidates may be.
      }
    }
    for (final lib in candidates) {
      try {
        lib.lookup<ffi.NativeFunction>('openpty');
        return lib;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  static int Function(
          ffi.Pointer<ffi.Int32>,
          ffi.Pointer<ffi.Int32>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Void>)?
      _openptyFn;

  static int Function(
          ffi.Pointer<ffi.Int32>,
          ffi.Pointer<ffi.Int32>,
          ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.Void>,
          ffi.Pointer<ffi.Void>)? get _openpty {
    final lib = _openptyLib;
    if (lib == null) return null;
    return _openptyFn ??= lib.lookupFunction<
        ffi.Int32 Function(
            ffi.Pointer<ffi.Int32>,
            ffi.Pointer<ffi.Int32>,
            ffi.Pointer<ffi.Uint8>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>),
        int Function(
            ffi.Pointer<ffi.Int32>,
            ffi.Pointer<ffi.Int32>,
            ffi.Pointer<ffi.Uint8>,
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Void>)>('openpty');
  }

  static ffi.Pointer<ffi.Uint8> _malloc(int bytes) {
    final p = _mallocFn(bytes);
    if (p == ffi.nullptr) throw StateError('malloc($bytes) failed');
    return p.cast();
  }

  static void _free(ffi.Pointer<ffi.Uint8> p) => _freeFn(p.cast());

  static final _mallocFn = _libc.lookupFunction<
      ffi.Pointer<ffi.Void> Function(ffi.IntPtr),
      ffi.Pointer<ffi.Void> Function(int)>('malloc');
  static final _freeFn = _libc.lookupFunction<
      ffi.Void Function(ffi.Pointer<ffi.Void>),
      void Function(ffi.Pointer<ffi.Void>)>('free');

  static final _isatty = _libc.lookupFunction<
      ffi.Int32 Function(ffi.Int32),
      int Function(int)>('isatty');

  static final _write = _libc.lookupFunction<
      ffi.Int64 Function(ffi.Int32, ffi.Pointer<ffi.Uint8>, ffi.Int64),
      int Function(int, ffi.Pointer<ffi.Uint8>, int)>('write');
  static final _read = _libc.lookupFunction<
      ffi.Int64 Function(ffi.Int32, ffi.Pointer<ffi.Uint8>, ffi.Int64),
      int Function(int, ffi.Pointer<ffi.Uint8>, int)>('read');

  static final _poll = _libc.lookupFunction<
      ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.Uint64, ffi.Int32),
      int Function(ffi.Pointer<ffi.Uint8>, int, int)>('poll');

  static final _dup = _libc.lookupFunction<
      ffi.Int32 Function(ffi.Int32),
      int Function(int)>('dup');
  static final _dup2 = _libc.lookupFunction<
      ffi.Int32 Function(ffi.Int32, ffi.Int32),
      int Function(int, int)>('dup2');
  static final _close = _libc.lookupFunction<
      ffi.Int32 Function(ffi.Int32),
      int Function(int)>('close');

  static final _memcpy = _libc.lookupFunction<
      ffi.Pointer<ffi.Uint8> Function(ffi.Pointer<ffi.Uint8>,
          ffi.Pointer<ffi.Uint8>, ffi.Uint64),
      ffi.Pointer<ffi.Uint8> Function(
          ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, int)>('memcpy');

  static final _cfmakeraw = _libc.lookupFunction<
      ffi.Void Function(ffi.Pointer<ffi.Uint8>),
      void Function(ffi.Pointer<ffi.Uint8>)>('cfmakeraw');
  static final _tcgetattr = _libc.lookupFunction<
      ffi.Int32 Function(ffi.Int32, ffi.Pointer<ffi.Uint8>),
      int Function(int, ffi.Pointer<ffi.Uint8>)>('tcgetattr');
  static final _tcsetattr = _libc.lookupFunction<
      ffi.Int32 Function(ffi.Int32, ffi.Int32, ffi.Pointer<ffi.Uint8>),
      int Function(int, int, ffi.Pointer<ffi.Uint8>)>('tcsetattr');

  static final _fcntl = _libc.lookupFunction<
      ffi.Int32 Function(ffi.Int32, ffi.Int32, ffi.Int64),
      int Function(int, int, int)>('fcntl');

  static final _ioctl = _libc.lookupFunction<
      ffi.Int32 Function(ffi.Int32, ffi.Uint64, ffi.Pointer<ffi.Void>),
      int Function(int, int, ffi.Pointer<ffi.Void>)>('ioctl');
}

class _SavedTermios {
  final ffi.Pointer<ffi.Uint8> bytes;
  _SavedTermios(this.bytes);
}
