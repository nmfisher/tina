import 'dart:io';
import 'package:tina/tui.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import '../../lib/src/restart.dart';

Future<void> main(List<String> args) async {
  final device = terminalDevicePath()!;
  final assembly = SessionAssembly.start(
    providerFactory: (_) => ScriptedProvider([scriptedReply('before restart')]),
    options: AssemblyOptions(configPath: args[0], workingDirectory: args[1]),
  );
  assembly.host.commands.publish(
    Command(
      name: 'restart-test',
      description: 'test restart',
      handler: (_) => assembly.handleCommand('/quit'),
    ),
  );
  await runTui(TuiSession.wrap(assembly));
  stdout.writeln('RESTART_PARENT_CLOSED');
  exitCode = await restartInTerminal(Platform.resolvedExecutable, [
    '${Directory.current.path}/apps/tina_cli/bin/tina.dart',
    '--config',
    args[0],
    '--cwd',
    args[1],
  ], terminalDevice: device);
}
