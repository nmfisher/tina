import 'dart:ffi' as ffi;
import 'dart:typed_data';

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
/// fd 0 is restored after init, so the input path for the rest of the
/// session is exactly what it would have been without the guard.
class TerminalReplyGuard {
  TerminalReplyGuard({ReplyGuardOs? os}) : _os = os ?? ReplyGuardOs.posix();

  final ReplyGuardOs _os;

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

  /// Put the real stdin back on fd 0. No-op unless [prepare] returned true.
  void restore() {
    if (!_armed) return;
    _armed = false;
    try {
      _os.restoreStdin();
    } catch (_) {
      // fd 0 is the pty at this point; if swapping back fails the keyboard
      // is lost either way and there is nothing the caller could do.
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

  /// Undo the detour: real stdin back on fd 0, non-blocking as notcurses
  /// expects fd 0 to be, pty fds closed.
  void restoreStdin();

  /// Release resources held by a detour without touching fd 0. Called when
  /// the guard aborts between [installDetour] and [restoreStdin].
  void abandon();

  /// The live POSIX implementation.
  factory ReplyGuardOs.posix() = PosixReplyGuardOs;
}

class PosixReplyGuardOs implements ReplyGuardOs {
  int? _savedStdin;
  int? _master;

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
  void restoreStdin() {
    final saved = _savedStdin;
    final master = _master;
    _savedStdin = null;
    _master = null;
    if (saved == null || saved < 0) return;
    // notcurses set O_NONBLOCK on fd 0 while fd 0 was the pty slave; the
    // real stdin still carries its original flags, so set it before the
    // swap and the input pump's poll-then-read pattern keeps working.
    final flags = _fcntl(saved, _fGetFl, 0);
    if (flags >= 0) _fcntl(saved, _fSetFl, flags | _oNonblock);
    _dup2(saved, 0);
    _close(saved);
    if (master != null && master >= 0) _close(master);
  }

  @override
  void abandon() {
    final master = _master;
    _master = null;
    _savedStdin = null;
    if (master != null && master >= 0) _close(master);
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
}

class _SavedTermios {
  final ffi.Pointer<ffi.Uint8> bytes;
  _SavedTermios(this.bytes);
}
