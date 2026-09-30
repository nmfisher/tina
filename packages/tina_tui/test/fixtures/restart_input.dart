import 'dart:io';
import '../../lib/src/restart.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--child')) {
    stdin.echoMode = false;
    stdin.lineMode = false;
    stdout.writeln('RESTART_READY');
    final buffer = <int>[];
    await for (final bytes in stdin) {
      buffer.addAll(bytes);
      if (buffer.contains(10)) {
        stdout.writeln('RECEIVED:${String.fromCharCodes(buffer).trim()}');
        break;
      }
    }
    return;
  }
  final device = terminalDevicePath();
  final subscription = stdin.listen((_) {});
  await subscription.cancel();
  exitCode = await restartInTerminal(
      Platform.resolvedExecutable,
      [
        Platform.script.toFilePath(),
        '--child',
      ],
      terminalDevice: device);
}
