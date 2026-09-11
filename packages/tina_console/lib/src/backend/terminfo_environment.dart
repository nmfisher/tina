import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Static ncurses archives can retain their build machine's database prefix.
/// Darwin ships terminfo separately; use installed locations unless the user
/// explicitly chose a database. Native getenv reads the process environment.
void configureMacosTerminfo({
  bool? isMacOS,
  Map<String, String>? environment,
  bool Function(String)? directoryExists,
  void Function(String, String)? setEnvironment,
}) {
  if (!(isMacOS ?? Platform.isMacOS)) return;
  final env = environment ?? Platform.environment;
  if ((env['TERMINFO']?.isNotEmpty ?? false) ||
      (env['TERMINFO_DIRS']?.isNotEmpty ?? false)) {
    return;
  }
  final exists = directoryExists ?? (path) => Directory(path).existsSync();
  final directories = const [
    '/usr/share/terminfo',
    '/opt/homebrew/share/terminfo',
    '/opt/homebrew/opt/ncurses/share/terminfo',
    '/usr/local/share/terminfo',
    '/usr/local/opt/ncurses/share/terminfo',
  ].where(exists).toList();
  if (directories.isEmpty) return;
  (setEnvironment ?? _setEnvironment)('TERMINFO_DIRS', directories.join(':'));
}

void _setEnvironment(String key, String value) {
  final setenv = DynamicLibrary.process().lookupFunction<
      Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32),
      int Function(Pointer<Utf8>, Pointer<Utf8>, int)>('setenv');
  final name = key.toNativeUtf8();
  final text = value.toNativeUtf8();
  try {
    if (setenv(name, text, 1) != 0) {
      throw StateError('Could not configure the native terminfo search path');
    }
  } finally {
    calloc.free(name);
    calloc.free(text);
  }
}
