import 'dart:io';
import '../../lib/src/restart.dart';

Future<void> main() async {
  // Consume input just as the old editor did, then cancel before restarting.
  final subscription = stdin.listen((_) {});
  await subscription.cancel();
  exitCode = await restartInTerminal('/bin/sh', [
    '-c',
    r'printf "RESTART_READY\n"; IFS= read -r line; printf "RECEIVED:%s\n" "$line"',
  ]);
}
