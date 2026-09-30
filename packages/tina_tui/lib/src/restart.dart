import 'dart:io';

/// Reopen the controlling terminal after the old app closes its input backend.
/// Dart may close stdin's descriptor when its subscription is cancelled;
/// inheriting that descriptor leaves the new app unable to accept input.
Future<int> restartInTerminal(String executable, List<String> arguments) async {
  final child = await Process.start(
      '/bin/sh',
      [
        '-c',
        r'exec "$@" </dev/tty >/dev/tty 2>&1',
        'tina-restart',
        executable,
        ...arguments,
      ],
      mode: ProcessStartMode.inheritStdio);
  return await child.exitCode;
}
