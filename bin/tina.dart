import 'dart:io';
import 'package:tina_tui/tina_tui.dart';
import 'package:tina/version.g.dart';

Future<void> main(List<String> args) async {
  exitCode = await runCli(args, version: tinaVersion);
}
