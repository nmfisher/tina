import 'dart:ffi';
import 'dart:io' as io;

/// Check whether the notcurses shared library is available on this system.
///
/// Returns `true` if `libnotcurses.so` (Linux) or `libnotcurses.dylib`
/// (macOS) can be loaded. Returns `false` on any failure — missing
/// library, incompatible architecture, etc.
///
/// This function is safe to call even when notcurses is not installed;
/// it never throws.
bool isNotcursesAvailable() {
  try {
    final names = io.Platform.isLinux
        ? ['libnotcurses.so', 'libnotcurses.so.3']
        : io.Platform.isMacOS
            ? [
                'libnotcurses.dylib',
                '/opt/homebrew/opt/notcurses/lib/libnotcurses.dylib',
                '/usr/local/opt/notcurses/lib/libnotcurses.dylib',
              ]
            : <String>[];
    for (final name in names) {
      try {
        DynamicLibrary.open(name);
        return true;
      } catch (_) {
        continue;
      }
    }
  } catch (_) {
    // FFI not available or other platform issue.
  }
  return false;
}
