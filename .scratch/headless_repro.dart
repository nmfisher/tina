// Scratch repro of the headless goal path against a local stub server.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('headless-repro-');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final config = File('${directory.path}/config')
    ..writeAsStringSync('''
[default]
provider = "local"
model = "goal"
[providers.local]
base_url = "http://127.0.0.1:${server.port}/v1"
api_key = "fixture"
models = ["goal"]
[plugins]
enabled = ["tina/goals"]
''');
  server.listen((request) async {
    final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
    final isJudge = (body['messages'] as List).any(
      (message) =>
          message['role'] == 'system' &&
          message['content'].toString().contains('You judge whether'),
    );
    print('[server] ${request.uri.path} isJudge=$isJudge');
    request.response.headers.contentType = ContentType('text', 'event-stream');
    request.response.write(
      'data: ${jsonEncode({
        'choices': [
          {
            'index': 0,
            'delta': {'content': 'work complete'},
            'finish_reason': 'stop',
          },
        ],
      })}\n\ndata: [DONE]\n\n',
    );
    await request.response.close();
  });
  final child = await Process.start(Platform.resolvedExecutable, [
    'run',
    'bin/tina.dart',
    '--config',
    config.path,
    '--cwd',
    directory.path,
    '--no-sandbox',
    '--goal',
    'finish',
  ]);
  final out = <String>[];
  child.stdout.transform(utf8.decoder).listen(out.add);
  final err = <String>[];
  child.stderr.transform(utf8.decoder).listen(err.add);
  final code = await child.exitCode.timeout(
    const Duration(seconds: 240),
    onTimeout: () {
      print('TIMEOUT waiting for child');
      child.kill();
      return -1;
    },
  );
  print('exitCode=$code');
  print('--- stdout ---');
  print(out.join());
  print('--- stderr ---');
  print(err.join());
  await server.close(force: true);
  try {
    directory.deleteSync(recursive: true);
  } catch (_) {}
}
