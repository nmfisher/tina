// Live probe (commit 10): start a REAL session through the app
// assembly (real plugin catalog, channel plugin included) with a
// recording provider, and print the rendered group-channel prompt
// section exactly as the model request carries it. Scratch.
import 'dart:io';

import 'package:tina/session.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

Future<void> main(List<String> args) async {
  final ws = Directory(args.isNotEmpty ? args.first : '/tmp/etiquette-live-ws')
    ..createSync(recursive: true);
  final config = File('/tmp/etiquette-live-config')
    ..writeAsStringSync('[default]\nmodel = "scripted"\n');

  final provider = ScriptedProvider([scriptedReply('ack')]);
  final app = SessionAssembly.start(
      options: AssemblyOptions(
          configPath: config.path, workingDirectory: ws.path),
      providerFactory: (_) => provider);
  try {
    await app.host.send('hello');
    final system = provider.requests.single.systemPrompt;
    final start = system.indexOf('<group-channel>');
    final end = system.indexOf('</group-channel>');
    if (start < 0 || end < 0) {
      print('NO group-channel section in the assembled system prompt!');
      exitCode = 1;
      return;
    }
    print('--- rendered <group-channel> section (from the real session '
        'request; ${system.length} chars of system prompt total) ---');
    print(system.substring(start, end + '</group-channel>'.length));
  } finally {
    app.close();
  }
}
