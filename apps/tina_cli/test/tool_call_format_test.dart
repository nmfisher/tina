import 'dart:convert';
import 'dart:io';

import 'package:classification/plugin.dart';
import 'package:classification/typesafe_classifier.dart';
import 'package:test/test.dart';
import 'package:tina/session.dart';
import 'package:tina/src/plugin_catalog.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_settings/tina_settings.dart';

TurnContext _call(String name, Map<String, Object?> input) => TurnContext(
  CancelToken(),
  input: const Input('inspect the PR', id: 'one'),
  messages: [],
  promptSections: [],
  pinnedTools: [],
  call: ToolUse(id: 'call', name: name, input: input),
);

class _Output implements Terminal {
  @override
  void writeln([String? line]) {}
  @override
  Future<String> ask(String prompt) async => throw UnimplementedError();
}

void main() {
  test(
    'configured guard uses Typesafe and follows scoped settings live',
    () async {
      final directory = Directory.systemTemp.createTempSync('tool-format-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bodies = <Map<String, dynamic>>[];
      final credentials = <String?>[];
      final served = <Future<void>>[];
      server.listen((request) {
        served.add(() async {
          credentials.add(
            request.headers.value(HttpHeaders.authorizationHeader),
          );
          final body =
              jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, dynamic>;
          bodies.add(body);
          final input = (body['state'] as Map)['input'] as Map;
          final choice = input.containsKey('command') ? 'BAD' : 'GOOD';
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'model': 'jev-format-fixture',
              'usage': {},
              'answers': {
                'tool_call_format': {
                  'type': 'choice',
                  'choice': choice,
                  'confidence': .99,
                  'probabilities': {
                    'GOOD': choice == 'GOOD' ? 1 : 0,
                    'BAD': choice == 'BAD' ? 1 : 0,
                  },
                },
              },
            }),
          );
          await request.response.close();
        }());
      });
      final config = File('${directory.path}/config')
        ..writeAsStringSync('''
[default]
model = "conversation-fixture"
[plugins]
enabled = ["tina/classification"]
[typesafe]
api_key = "fixture-typesafe-key"
model = "jev-format-fixture"
endpoint = "http://127.0.0.1:${server.port}/judge"
''');
      final assembly = SessionAssembly.start(
        options: AssemblyOptions(
          configPath: config.path,
          workingDirectory: directory.path,
        ),
        terminal: _Output(),
        providerFactory: (_) => ScriptedProvider([]),
      );
      try {
        final plugin = assembly.host.plugins
            .whereType<ClassificationPlugin>()
            .single;
        final reviewer = plugin.toolCalls!;
        Duration transportTimeout() {
          final lease = reviewer.open()!;
          try {
            return (lease.service as TypeSafeJudgmentService).config.timeout;
          } finally {
            lease.close();
          }
        }

        expect(transportTimeout(), const Duration(seconds: 60));
        expect(assembly.settings.read(toolCallFormatSetting).value, true);
        expect(
          assembly.settings.catalog[toolCallFormatSetting.id],
          toolCallFormatSetting,
        );
        final wrapped = _call('bash', {
          'command': 'cd /workspace; gh pr view 429',
        });
        await plugin.beforeToolCall(wrapped);
        expect(wrapped.decision.kind, DecisionKind.deny);
        expect(bodies, hasLength(1));
        expect(credentials.single, 'Bearer fixture-typesafe-key');
        expect(bodies.single['model'], 'jev-format-fixture');
        expect(bodies.single['questions'], contains('tool_call_format'));
        expect(plugin.trace.snapshot.exchanges.single.outcome?.label, 'BAD');

        for (final entry in [
          (SettingScope.global, 90),
          (SettingScope.workspace, 120),
          (SettingScope.session, 180),
        ]) {
          assembly.settings.set(
            toolCallFormatTimeoutSetting,
            entry.$2,
            entry.$1,
          );
          expect(transportTimeout(), Duration(seconds: entry.$2));
          expect(plugin.toolCalls, same(reviewer));
        }
        for (final invalid in [0, -1, 301]) {
          expect(
            () => assembly.settings.set(
              toolCallFormatTimeoutSetting,
              invalid,
              SettingScope.session,
            ),
            throwsFormatException,
          );
        }
        assembly.settings.set(
          toolCallFormatSetting,
          false,
          SettingScope.session,
        );
        final skipped = _call('exec', {
          'program': 'gh',
          'args': ['pr', 'view', '429'],
        });
        await plugin.beforeToolCall(skipped);
        expect(skipped.decision.kind, DecisionKind.allow);
        expect(bodies, hasLength(1));
        assembly.settings.removeOverride(
          toolCallFormatSetting,
          SettingScope.session,
        );
        await plugin.beforeToolCall(skipped);
        expect(skipped.decision.kind, DecisionKind.allow);
        expect(bodies, hasLength(2));
        expect(bodies.last['state'], {
          'tool': 'exec',
          'current_task': 'inspect the PR',
          'workspace': directory.path,
          'input': {
            'program': 'gh',
            'args': ['pr', 'view', '429'],
          },
        });
        expect(plugin.trace.snapshot.exchanges.last.outcome?.label, 'GOOD');
        expect(
          plugin.trace.snapshot.exchanges.last.title,
          'Command formatting',
        );
        final file = _call('edit', {
          'filePath': 'lib/main.dart',
          'oldString': 'private old contents',
          'newString': 'private new contents',
        });
        await plugin.beforeToolCall(file);
        expect(file.decision.kind, DecisionKind.allow);
        expect(bodies, hasLength(3));
        final state = bodies.last['state'] as Map;
        expect(state['workspace'], directory.path);
        expect(state['input'], {'filePath': 'lib/main.dart'});
        expect(
          (state['path_context'] as Map)['resolved_lexically'],
          '${directory.path}/lib/main.dart',
        );
        expect((state['path_context'] as Map)['existence'], 'not_checked');
        expect(jsonEncode(state), isNot(contains('private')));
        expect(plugin.trace.snapshot.exchanges.last.title, 'File path check');
        expect(
          jsonEncode(
            plugin.trace.snapshot.exchanges.map((e) => e.request).toList(),
          ),
          isNot(contains('fixture-typesafe-key')),
        );
      } finally {
        assembly.close();
        await server.close(force: true);
        await Future.wait(served);
        directory.deleteSync(recursive: true);
      }
    },
  );
}
