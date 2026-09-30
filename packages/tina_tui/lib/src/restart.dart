import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Capture the actual terminal device before the old input reader closes fd 0.
/// On macOS, Dart's asynchronous reader cannot use the /dev/tty alias.
String terminalDevicePath() {
  final ttyname = DynamicLibrary.process().lookupFunction<
      Pointer<Utf8> Function(Int32), Pointer<Utf8> Function(int)>('ttyname');
  final path = ttyname(0);
  if (path == nullptr) throw StateError('stdin has no terminal device');
  return path.toDartString();
}

Future<int> restartInTerminal(String executable, List<String> arguments,
    {required String terminalDevice}) async {
  final child = await Process.start(
      '/bin/sh',
      [
        '-c',
        r'tina_restart_tty="$1"; shift; exec "$@" <"$tina_restart_tty" >"$tina_restart_tty" 2>&1',
        'tina-restart',
        terminalDevice,
        executable,
        ...arguments,
      ],
      mode: ProcessStartMode.inheritStdio);
  return await child.exitCode;
}
