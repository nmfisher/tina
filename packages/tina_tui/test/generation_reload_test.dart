import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_tui/tina_tui.dart';

void main() {
  test('saved generation changes reach next request without resetting session',
      () async {
    final directory =
        Directory.systemTemp.createTempSync('tina-generation-reload-');
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
    void save(int max, String effort, {String model = 'first'}) {
      config.writeAsStringSync('''
[default]
provider = "local"
model = "$model"
[providers.local]
base_url = "http://127.0.0.1:${server.port}/v1"
api_key = "fixture"
models = ["first", "second"]
max_output = $max
reasoning_effort = "$effort"
[plugins]
enabled = []
''');
    }

    save(1000, 'low');
    final assembly = TuiAssembly.start(
        options: AssemblyOptions(
            configPath: config.path, workingDirectory: directory.path));
    addTearDown(() async {
      assembly.close();
      await server.close(force: true);
      directory.deleteSync(recursive: true);
    });
    final id = assembly.host.session.id;
    await assembly.host.send('first question');
    expect(bodies.single['max_tokens'], 1000);
    expect(bodies.single['reasoning_effort'], 'low');
    save(2000, 'high', model: 'second');
    assembly.applySavedGeneration();
    await assembly.host.send('second question');
    expect(assembly.host.session.id, id);
    expect(assembly.host.model, 'local/first');
    expect(bodies.last['model'], 'first');
    expect(bodies.last['max_tokens'], 2000);
    expect(bodies.last['reasoning_effort'], 'high');
    expect((bodies.last['messages'] as List).length, greaterThan(2));
    save(3000, 'low');
    assembly.applySavedGeneration();
    await assembly.host.send('third question');
    expect(bodies.last['max_tokens'], 3000);
    expect(bodies.last['reasoning_effort'], 'low');
  });
}
