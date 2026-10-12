import 'dart:io';
import 'package:tina/tina.dart';

Future<void> main(List<String> args) async {
  exitCode = await runCli(
    args,
    locateTerminalDevice: () {
      // The restart lookup must precede raw mode and the startup input reader.
      if (!stdin.echoMode || !stdin.lineMode) {
        throw StateError('restart lookup ran after terminal initialization');
      }
      stdout.writeln('RESTART_DEVICE_UNAVAILABLE');
      // Linux ttyname can fail even when isatty succeeds. The application and
      // resume picker must still read usable input without this optional path.
      return null;
    },
  );
}
