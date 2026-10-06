import 'dart:io';
import 'package:tina_tui/tina_tui.dart';

Future<void> main(List<String> args) async {
  if (await initializeProcessLauncher(args)) return;
  exitCode = await runCli(args);
}
