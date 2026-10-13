import 'dart:io';
import 'package:test/test.dart';
import 'package:tina/tina.dart';
import 'package:tina/src/plugin_catalog.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';

final class _ReportPlugin extends AgentPlugin {
  _ReportPlugin(this.closed);
  final void Function() closed;
  @override
  String get id => 'acme/report';
  @override
  void closeSession() => closed();
}

void main() {
  test(
    'registered plugin command runs through CLI and shuts down its session',
    () async {
      final dir = Directory.systemTemp.createTempSync('plugin-cli-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final config = File('${dir.path}/config')
        ..writeAsStringSync('''
[default]
provider = "local"
model = "fixture"
[providers.local]
base_url = "http://127.0.0.1:1/v1"
api_key = "fixture"
models = ["fixture"]
[plugins]
enabled = ["acme/report"]
''');
      const option = CliOption('report', description: 'Generate a report.');
      var registrations = 0;
      var builds = 0;
      var closes = 0;
      final events = <String>[];
      void register(PluginRegistry<SessionPluginContext> registry) {
        registrations++;
        registry.register(
          'acme/report',
          (_) {
            builds++;
            return _ReportPlugin(() => closes++);
          },
          description: 'Reports',
          operations: {
            'report': (plugin, arguments, context) async {
              expect(plugin, isA<_ReportPlugin>());
              events.add('run:${arguments['value']}');
              context.writeLine('report completed');
              return const SessionResult(stopReason: StopReason.complete);
            },
          },
          cli: PluginCli(
            options: [option],
            sessionCommand: (args) {
              final value = args[option];
              if (value == null) return null;
              return CliSessionCommand(
                option: option,
                operation: 'report',
                prepare: (_) async {
                  if (value == 'invalid')
                    throw const FormatException('bad report');
                  events.add('prepare:$value');
                  return {'value': value};
                },
              );
            },
          ),
        );
      }

      final args = ['--config', config.path, '--cwd', dir.path];
      expect(await runCli([...args, '--help'], registerPlugins: register), 0);
      expect(builds, 0);
      expect(
        await runCli([...args, '--report=invalid'], registerPlugins: register),
        64,
      );
      expect(builds, 0);
      expect(events, isEmpty);
      expect(
        await runCli(
          [...args, '--report=summary'],
          registerPlugins: register,
          locateTerminalDevice: () =>
              throw StateError('headless has no terminal'),
        ),
        0,
      );
      expect(events, ['prepare:summary', 'run:summary']);
      expect(registrations, 3);
      expect(builds, 1);
      expect(closes, 1);
      expect(File('${dir.path}/.tina/sessions.db').existsSync(), false);

      config.writeAsStringSync(
        config.readAsStringSync().replaceFirst('["acme/report"]', '[]'),
      );
      expect(
        await runCli([...args, '--report=summary'], registerPlugins: register),
        78,
      );
      expect(builds, 1);
      expect(closes, 1);
      expect(events.where((e) => e.startsWith('run:')), ['run:summary']);
    },
  );
}
