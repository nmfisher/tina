import 'dart:io';

import 'package:tina_cli/tina_cli.dart';

/// The entry point is deliberately thin: bind the real terminal to the
/// shell's two seams (the writer, the line reader) and hand over. All
/// decisions live in `lib/src/` where the tests drive them.
Future<void> main(List<String> args) async {
  String? configPath;
  var workingDirectory = Directory.current.path;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--config' && i + 1 < args.length) {
      configPath = args[++i];
    } else if (a == '--cwd' && i + 1 < args.length) {
      workingDirectory = args[++i];
    } else if (a == '--help' || a == '-h') {
      stdout.writeln(
          'usage: tina-shell [--config ~/.tina/config] [--cwd DIR]');
      return;
    } else {
      stdout.writeln('unknown argument: $a');
      stdout.writeln(
          'usage: tina-shell [--config ~/.tina/config] [--cwd DIR]');
      exitCode = 64;
      return;
    }
  }
  final shell = Shell.start(
    writer: const IoShellWriter(),
    options: ShellOptions(
      configPath: configPath,
      workingDirectory: workingDirectory,
    ),
  );
  await runShell(
    shell: shell,
    readLine: () async => stdin.readLineSync(),
  );
}
