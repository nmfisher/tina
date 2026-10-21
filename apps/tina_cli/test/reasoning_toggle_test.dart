import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina/session.dart';
import 'package:tina/tui.dart';

void main() {
  test('/reasoning applies to the next request and /reasoning auto reverts',
      () async {
    final directory =
        Directory.systemTemp.createTempSync('tina-reasoning-toggle-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bodies = <Map<String, dynamic>>[];
    server.listen((request) async {
      bodies.add(jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>);
      request.response.headers.contentType =
          ContentType('text', 'event-stream');
      request.response.write('data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {'content': 'answer'},
                'finish_reason': 'stop'
              }
            ],
            'usage': {'prompt_tokens': 3, 'completion_tokens': 2},
          })}\n\ndata: [DONE]\n\n');
      await request.response.close();
    });
    final config = File('${directory.path}/config');
    config.writeAsStringSync('''
[default]
provider = "local"
model = "first"
[providers.local]
base_url = "http://127.0.0.1:${server.port}/v1"
api_key = "fixture"
models = ["first"]
max_output = 1000
''');
    final assembly = SessionAssembly.start(
        options: AssemblyOptions(
            configPath: config.path, workingDirectory: directory.path));
    addTearDown(() async {
      assembly.close();
      await server.close(force: true);
      directory.deleteSync(recursive: true);
    });

    // Baseline: the config file sets no effort, so the wire carries none.
    await assembly.host.send('warm up');
    expect(bodies.last['max_tokens'], 1000);
    expect(bodies.last.containsKey('reasoning_effort'), isFalse);

    // /reasoning high writes the session scope; the next request carries it.
    await assembly.handleCommand('/reasoning high');
    await assembly.host.send('second question');
    expect(bodies.last['reasoning_effort'], 'high');
    expect(bodies.last['max_tokens'], 1000);
    final sessionId = assembly.host.session.id;

    // auto removes the override: the wire effort disappears again.
    await assembly.handleCommand('/reasoning auto');
    await assembly.host.send('third question');
    expect(assembly.host.session.id, sessionId);
    expect(bodies.last.containsKey('reasoning_effort'), isFalse);

    // An unknown level is refused without touching anything.
    await assembly.handleCommand('/reasoning absurd');
    await assembly.host.send('fourth question');
    expect(bodies.last.containsKey('reasoning_effort'), isFalse);
  });

  test('a session-scoped /reasoning write does not rewrite the config file',
      () async {
    final directory =
        Directory.systemTemp.createTempSync('tina-reasoning-persist-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bodies = <Map<String, dynamic>>[];
    server.listen((request) async {
      bodies.add(jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>);
      request.response.headers.contentType =
          ContentType('text', 'event-stream');
      request.response.write('data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {'content': 'answer'},
                'finish_reason': 'stop'
              }
            ],
            'usage': {'prompt_tokens': 3, 'completion_tokens': 2},
          })}\n\ndata: [DONE]\n\n');
      await request.response.close();
    });
    final config = File('${directory.path}/config');
    config.writeAsStringSync('''
[default]
provider = "local"
model = "first"
[providers.local]
base_url = "http://127.0.0.1:${server.port}/v1"
api_key = "fixture"
models = ["first"]
max_output = 1000
''');
    final assembly = SessionAssembly.start(
        options: AssemblyOptions(
            configPath: config.path, workingDirectory: directory.path));
    addTearDown(() async {
      assembly.close();
      await server.close(force: true);
      directory.deleteSync(recursive: true);
    });

    await assembly.handleCommand('/reasoning high');
    final onDisk = config.readAsStringSync();
    expect(onDisk.contains('reasoning_effort'), isFalse,
        reason: 'a session-scoped /reasoning write must not rewrite the config');
  });
}
