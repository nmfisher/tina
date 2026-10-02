import 'dart:io';
import 'package:tina_tui/tina_tui.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import '../../lib/src/restart.dart';

Future<void> main(List<String> args) async {
  final device = terminalDevicePath()!;
  final assembly = TuiAssembly.start(
      providerFactory: (_) =>
          ScriptedProvider([scriptedReply('before restart')]),
      options: AssemblyOptions(configPath: args[0], workingDirectory: args[1]));
  assembly.host.commands.publish(Command(
      name: 'restart-test',
      description: 'test restart',
      handler: (_) => assembly.handleCommand('/quit')));
  await runApp(TuiSession.wrap(assembly));
  stdout.writeln('RESTART_PARENT_CLOSED');
  exitCode = await restartInTerminal(
      Platform.resolvedExecutable,
      [
        '${Directory.current.path}/bin/tina.dart',
        '--config',
        args[0],
        '--cwd',
        args[1],
      ],
      terminalDevice: device);
}
