import 'dart:ffi' as ffi;
import 'dart:io' show Platform;

/// Unbinds VDISCARD (Ctrl+O / 0x0F) on the tty so the byte reaches the app.
///
/// On macOS's BSD line discipline, 0x0F is the VDISCARD toggle ("throw away
/// pending output"), honored whenever IEXTEN is set — and notcurses' termios
/// setup leaves IEXTEN on, so the discipline eats Ctrl+O before the input
/// pump ever sees it. Linux has no VDISCARD, so this is a macOS-only problem.
///
/// The surgical fix is to set `c_cc[VDISCARD]` to `_POSIX_VDISABLE` (0)
/// rather than clearing IEXTEN: unbinding the character disables exactly the
/// discard toggle and leaves everything else IEXTEN gates (LNEXT, quote
/// handling) alone. A no-op when VDISCARD is already disabled — e.g. the
/// user ran `stty discard undef` themselves — and best-effort throughout:
/// any failure leaves the terminal exactly as it was.
class DiscardUnbinder {
  /// Unbind VDISCARD on [fd] if it is a macOS tty with the char bound.
  ///
  /// Returns true when the terminal was changed. Never throws.
  static bool unbind(int fd, {DiscardUnbinderOs? os}) {
    try {
      final impl = os ?? DiscardUnbinderOs.posix();
      if (!impl.isBound(fd)) return false;
      return impl.disable(fd);
    } catch (_) {
      return false;
    }
  }
}

/// The fd-level operations [DiscardUnbinder] needs, split out for tests.
abstract class DiscardUnbinderOs {
  factory DiscardUnbinderOs.posix() = PosixDiscardUnbinderOs;

  /// True when [fd] is a macOS tty whose VDISCARD is bound (not the disable
  /// byte). False on non-macOS platforms — there is no VDISCARD there.
  bool isBound(int fd);

  /// Write _POSIX_VDISABLE into the tty's VDISCARD slot. Returns true on
  /// success.
  bool disable(int fd);
}

class PosixDiscardUnbinderOs implements DiscardUnbinderOs {
  // Linux struct termios has no VDISCARD slot; nothing to do there.
  static final bool _macOS = Platform.isMacOS;

  @override
  bool isBound(int fd) {
    if (!_macOS) return false;
    final t = _malloc(termiosBytes);
    try {
      if (_tcgetattr(fd, t) != 0) return false;
      return t[_vdiscardOffset] != _posixVdisable;
    } finally {
      _free(t);
    }
  }

  @override
  bool disable(int fd) {
    if (!_macOS) return false;
    final t = _malloc(termiosBytes);
    try {
      if (_tcgetattr(fd, t) != 0) return false;
      t[_vdiscardOffset] = _posixVdisable;
      return _tcsetattr(fd, _tcsanow, t) == 0;
    } finally {
      _free(t);
    }
  }

  // -- FFI plumbing -------------------------------------------------------

  /// Room for struct termios on macOS (60 bytes), linux/arm64 and
  /// linux/x86_64, with slack. tcgetattr writes at most the real size, so
  /// over-allocating is safe; the slack is never read back.
  static const int termiosBytes = 128;
  static const int _tcsanow = 0;

  /// _POSIX_VDISABLE: 0 everywhere Apple/Darwin and glibc ship.
  static const int _posixVdisable = 0;

  /// macOS struct termios: four `unsigned long` flags (c_iflag, c_oflag,
  /// c_cflag, c_lflag — 8 bytes each) then cc_t c_cc[NCCS] at byte 32.
  /// VDISCARD is index 15 (sys/termios.h), so its byte is 32 + 15.
  static const int _vdiscardOffset = 32 + 15;

  static final ffi.DynamicLibrary _libc = ffi.DynamicLibrary.process();

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

  static final _tcgetattr = _libc.lookupFunction<
      ffi.Int32 Function(ffi.Int32, ffi.Pointer<ffi.Uint8>),
      int Function(int, ffi.Pointer<ffi.Uint8>)>('tcgetattr');
  static final _tcsetattr = _libc.lookupFunction<
      ffi.Int32 Function(ffi.Int32, ffi.Int32, ffi.Pointer<ffi.Uint8>),
      int Function(int, int, ffi.Pointer<ffi.Uint8>)>('tcsetattr');
}
