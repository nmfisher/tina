import 'dart:async';

import 'package:tina_engine/src/terminal/pty_runner.dart';

Future<void> main() async {
  print('spawning...');
  final conn = await const PtyRunner().spawn(const PtySpawnRequest(
    executable: '/bin/sh',
    arguments: ['-c', 'echo hi; exit 3'],
    environment: {'PATH': '/usr/bin:/bin'},
  ));
  print('pid=' + conn.pid.toString());
  conn.output.listen((b) => print('OUT len=' + b.length.toString() + ' [' + String.fromCharCodes(b).trim() + ']'),
      onError: (e) => print('OUTERR ' + e.toString()),
      onDone: () => print('OUT done'));
  final code = await conn.done.timeout(const Duration(seconds: 5),
      onTimeout: () => -99);
  print('exit=' + code.toString());
  await conn.close();
  print('OK');
  await Future.delayed(const Duration(milliseconds: 100));
}
