import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina/tina.dart';
import 'package:tina/session.dart';
import 'package:tina/tui.dart';
import 'package:tina_persistence/tina_persistence.dart';
import 'package:tina_goals/tina_goals.dart';

void main() {
  test(
    'headless goal, model override, continue and unattended approvals',
    () async {
      final directory = Directory.systemTemp.createTempSync('tina-headless-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
        directory.deleteSync(recursive: true);
      });
      final requests = <Map<String, dynamic>>[];
      final credentials = <String?>[];
      final config = File('${directory.path}/config')
        ..writeAsStringSync('''
[default]
provider = "local"
model = "first"
[providers.local]
base_url = "http://127.0.0.1:${server.port}/v1"
api_key = "fixture"
models = ["first", "second"]
[providers.another]
base_url = "http://127.0.0.1:${server.port}/v1"
api_key = "another-fixture"
models = ["remote"]
[plugins]
enabled = ["tina/persistence", "tina/session-controls", "tina/goals"]
''');
      var tools = false;
      var fail = false;
      var verdict = 'VERDICT: yes — completed';
      server.listen((request) async {
        final body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        final judging = (body['tools'] as List?)?.isNotEmpty != true;
        if (!judging) {
          requests.add(body);
          credentials.add(request.headers.value('authorization'));
        }
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        if (fail) {
          await request.response.close();
          return;
        }
        final toolCall = tools && !judging;
        final delta = judging
            ? {'content': verdict}
            : toolCall
            ? {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'write-1',
                    'type': 'function',
                    'function': {
                      'name': 'write',
                      'arguments': jsonEncode({
                        'path': '${directory.path}/should-not-exist',
                        'content': 'denied',
                      }),
                    },
                  },
                ],
              }
            : {'content': 'headless answer'};
        request.response.write(
          'data: ${jsonEncode({
            'choices': [
              {'index': 0, 'delta': delta, 'finish_reason': toolCall ? 'tool_calls' : 'stop'},
            ],
          })}\n\n',
        );
        request.response.write('data: [DONE]\n\n');
        if (!judging) tools = false;
        await request.response.close();
      });
      final args = ['--config', config.path, '--cwd', directory.path];
      expect(
        await runCli([...args, '--goal', 'hello', '--model', 'second']),
        0,
      );
      expect(requests.single['model'], 'second');
      expect(await runCli([...args, '--continue', '--goal', 'next']), 0);
      expect(requests.last['model'], 'second');
      expect(
        (requests.last['messages'] as List).where((m) => m['role'] != 'system'),
        hasLength(3),
      );
      expect(
        await runCli([
          ...args,
          '--goal',
          'cross provider',
          '--model',
          'another/remote',
        ]),
        0,
      );
      expect(requests.last['model'], 'remote');
      expect(credentials.last, 'Bearer another-fixture');
      expect(await runCli([...args, '--continue', '--goal', 'restored']), 0);
      expect(requests.last['model'], 'remote');
      expect(credentials.last, 'Bearer another-fixture');
      tools = true;
      verdict = 'VERDICT: unclear — requested write was denied';
      expect(
        await runCli([
          ...args,
          '--goal',
          'write a file',
        ]).timeout(const Duration(seconds: 10)),
        1,
      );
      expect(File('${directory.path}/should-not-exist').existsSync(), false);
      final messages = requests.last['messages'] as List;
      expect(messages.any((m) => m['role'] == 'tool'), true);
      verdict = 'VERDICT: yes — completed';
      var root = Directory.current;
      while (!File('${root.path}/bin/tina.dart').existsSync()) {
        if (root.parent.path == root.path) {
          throw StateError('Cannot locate the CLI application');
        }
        root = root.parent;
      }
      final child = await Process.start(Platform.resolvedExecutable, [
        'run',
        'bin/tina.dart',
        ...args,
        '--no-sandbox',
        '--goal',
        '-',
      ], workingDirectory: root.path);
      final output = child.stdout.transform(utf8.decoder).join();
      final errors = child.stderr.transform(utf8.decoder).join();
      child.stdin.writeln('piped goal');
      await child.stdin.close();
      expect(
        await child.exitCode.timeout(const Duration(seconds: 30)),
        0,
        reason: await errors,
      );
      expect(await output, contains('headless answer'));
      expect(await errors, isNot(contains('provider error')));
      expect(
        (requests.last['messages'] as List).first['content'],
        contains('OS sandbox deliberately disabled'),
      );
      expect(
        (requests.last['messages'] as List).last['content'],
        'piped goal\n',
      );

      // Validate stdin after reading it, before opening a session or contacting
      // the provider. The literal '-' must never become the objective.
      // The process above covers the real stdin adapter; invalid inputs use the
      // same entry point without paying for another cold Dart startup each.
      for (final invalid in ['   ', 'x' * (goalMaxTextLength + 1)]) {
        final count = requests.length;
        expect(
          await runCli([
            ...args,
            '--goal',
            '-',
          ], readStdin: () async => invalid),
          64,
        );
        expect(requests, hasLength(count));
      }
      fail = true;
      expect(await runCli([...args, '--goal', 'fail']), 1);
      expect(await runCli([...args, '--goal', '   ']), 64);
      expect(await runCli([...args, '--models', 'local']), 0);
      final store = SessionStore.open(defaultSessionStorePath(directory.path));
      try {
        expect(store.list().any((s) => s.model == 'local/second'), true);
      } finally {
        store.close();
      }
    },
    // Leave room around the child's own 30-second deadline on shared CI hosts.
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'headless goals wait for verdicts and honor explicit turn bounds',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'tina-headless-goal-',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
        directory.deleteSync(recursive: true);
      });
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
      var turns = 0, judgments = 0;
      var invalidJudge = false;
      server.listen((request) async {
        final body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        final judging = (body['tools'] as List?)?.isNotEmpty != true;
        if (judging) {
          judgments++;
        } else {
          turns++;
        }
        final text = !judging
            ? 'goal work'
            : invalidJudge
            ? 'invalid verdict'
            : judgments.isEven
            ? 'VERDICT: yes — completed'
            : 'VERDICT: no — work remains';
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {'content': text},
                'finish_reason': 'stop',
              },
            ],
          })}\n\n',
        );
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      });
      final args = ['--config', config.path, '--cwd', directory.path];
      expect(
        await runCli([
          ...args,
          '--goal',
          'Finish the work',
          '--max-goal-turns',
          '2',
        ]),
        0,
      );
      expect(turns, 2);
      expect(judgments, 2);
      turns = 0;
      judgments = 0;
      expect(
        await runCli([
          ...args,
          '--goal',
          'Finish the work',
          '--max-goal-turns',
          '1',
        ]),
        1,
      );
      expect(turns, 1);
      expect(judgments, 1);
      invalidJudge = true;
      turns = 0;
      judgments = 0;
      expect(await runCli([...args, '--goal', 'Finish the work']), 1);
      expect(turns, 1);
      expect(judgments, 1);
      expect(
        await runCli([...args, '--goal', 'Work', '--max-goal-turns', '0']),
        64,
      );
      expect(await runCli([...args, '--max-goal-turns', '2']), 64);
      config.writeAsStringSync(
        config.readAsStringSync().replaceFirst(
          'enabled = ["tina/goals"]',
          'enabled = []',
        ),
      );
      final requestsBefore = turns + judgments;
      expect(await runCli([...args, '--goal', 'Work']), 78);
      expect(turns + judgments, requestsBefore);
    },
  );
}
