import 'dart:io';
import 'package:tina/tina.dart';
import 'package:tina/version.g.dart';

Future<void> main(List<String> args) async {
  if (await initializeProcessLauncher(args)) return;
  exitCode = await runCli(args, version: tinaVersion);
}
