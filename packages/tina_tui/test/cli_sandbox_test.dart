import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tui/tina_tui.dart';

void main() {
  test(
      '--no-sandbox reaches real CLI provider but headless approvals still deny',
      () async {
    final dir = Directory.systemTemp.createTempSync('tina-cli-sandbox-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
      dir.deleteSync(recursive: true);
    });
    final marker = '${dir.path}/must-not-run';
    final config = File('${dir.path}/config')..writeAsStringSync('''
[default]
provider = "local"
model = "fixture"
[providers.local]
base_url = "http://127.0.0.1:${server.port}/v1"
api_key = "fixture"
models = ["fixture"]
[plugins]
enabled = []
''');
    final requests = <Map<String, dynamic>>[];
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      requests.add(body);
      final tool = requests.length == 1;
      request.response.headers.contentType =
          ContentType('text', 'event-stream');
      request.response.write('data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': tool
                    ? {
                        'tool_calls': [
                          {
                            'index': 0,
                            'id': 'call',
                            'type': 'function',
                            'function': {
                              'name': 'exec',
                              'arguments': jsonEncode({
                                'program': 'touch',
                                'args': [marker]
                              })
                            }
                          }
                        ]
                      }
                    : {'content': 'done'},
                'finish_reason': tool ? 'tool_calls' : 'stop',
              }
            ]
          })}\n\n');
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });
    expect(
        await runCli([
          '--config',
          config.path,
          '--cwd',
          dir.path,
          '--no-sandbox',
          '--prompt',
          'try command'
        ]),
        0);
    final messages = requests.first['messages'] as List;
    final system =
        messages.firstWhere((m) => m['role'] == 'system')['content'] as String;
    expect(system, contains('OS sandbox deliberately disabled'));
    expect(system, contains('host filesystem and network access'));
    expect(
        system, contains('Permission modes and approval checks still apply'));
    expect(
        requests.last['messages'],
        contains(predicate((dynamic m) =>
            m['role'] == 'tool' &&
            (m['content'] as String).contains('denied'))));
    expect(File(marker).existsSync(), false);
    expect(File('${dir.path}/.tina/sessions.db').existsSync(), false);
  });

  for (final enabled in [true, false]) {
    test('OS confinement=$enabled is inherited by new panels', () {
      final dir = Directory.systemTemp.createTempSync('tina-panel-sandbox-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final assembly = TuiAssembly.start(
          providerFactory: (_) => ScriptedProvider([]),
          options: AssemblyOptions(
              configPath: '${dir.path}/missing',
              workingDirectory: dir.path,
              osSandbox: enabled));
      addTearDown(assembly.close);
      final panel = assembly.newSession(null);
      addTearDown(panel.close);
      expect(assembly.tools.osSandbox, enabled);
      expect(panel.tools.osSandbox, enabled);
      expect(panel.tools.mode, assembly.tools.mode);
    });
  }
}
