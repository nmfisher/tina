import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Preserve stdin before native initialization can replace it with a PTY or
/// change its modes. An ANSI fallback needs the original descriptor as well
/// as cooked terminal settings; restoring only Dart's echo/line flags is not
/// enough after a failed native capability probe.
final class TerminalStartupSnapshot {
  TerminalStartupSnapshot._(this._fd, this._modes, this._flags);
  final int _fd, _flags;
  final Pointer<Uint8> _modes;

  static TerminalStartupSnapshot capture() {
    final fd = _dup(0);
    if (fd < 0) throw StateError('Could not preserve terminal input');
    final modes = calloc<Uint8>(128);
    final flags = _fcntl(fd, _getFlags, 0);
    if (_tcgetattr(fd, modes) != 0 || flags < 0) {
      calloc.free(modes);
      _close(fd);
      throw StateError('Could not preserve terminal modes');
    }
    return TerminalStartupSnapshot._(fd, modes, flags);
  }

  void restore() {
    if (_dup2(_fd, 0) < 0 ||
        _tcsetattr(0, _applyNow, _modes) != 0 ||
        _fcntl(0, _setFlags, _flags) < 0) {
      throw StateError('Could not restore terminal input after native startup');
    }
    // Undo any terminal reporting/alternate-screen state left by partial init.
    stdout.write('\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l'
        '\x1b[?2004l\x1b[?1049l\x1b[?25h\x1b[0m');
  }

  void dispose() {
    _close(_fd);
    calloc.free(_modes);
  }

  static final _libc = DynamicLibrary.process();
  static const _getFlags = 3, _setFlags = 4, _applyNow = 0;
  static final _dup =
      _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('dup');
  static final _dup2 = _libc.lookupFunction<Int32 Function(Int32, Int32),
      int Function(int, int)>('dup2');
  static final _close =
      _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  static final _fcntl = _libc.lookupFunction<
      Int32 Function(Int32, Int32, VarArgs<(Int32,)>),
      int Function(int, int, int)>('fcntl');
  static final _tcgetattr = _libc.lookupFunction<
      Int32 Function(Int32, Pointer<Uint8>),
      int Function(int, Pointer<Uint8>)>('tcgetattr');
  static final _tcsetattr = _libc.lookupFunction<
      Int32 Function(Int32, Int32, Pointer<Uint8>),
      int Function(int, int, Pointer<Uint8>)>('tcsetattr');
}
