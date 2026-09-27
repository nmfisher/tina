import 'dart:io';

import 'package:tina_cli/tina_cli.dart';

/// The entry point is deliberately thin: bind the real terminal to the
/// shell's two seams (the writer, the line reader) and hand over. All
/// decisions live in `lib/src/` where the tests drive them.
Future<void> main(List<String> args) async {
  String? configPath;
  String? storePath;
  String? sessionId;
  var listOnly = false;
  var workingDirectory = Directory.current.path;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--config' && i + 1 < args.length) {
      configPath = args[++i];
    } else if (a == '--cwd' && i + 1 < args.length) {
      workingDirectory = args[++i];
    } else if (a == '--store' && i + 1 < args.length) {
      storePath = args[++i];
    } else if (a == '--resume' && i + 1 < args.length) {
      sessionId = args[++i];
    } else if (a == '--sessions') {
      listOnly = true;
    } else if (a == '--help' || a == '-h') {
      stdout.writeln('usage: tina-shell [--config ~/.tina/config] '
          '[--cwd DIR] [--store FILE] [--resume SESSION] [--sessions]');
      return;
    } else {
      stdout.writeln('unknown argument: $a');
      stdout.writeln('usage: tina-shell [--config ~/.tina/config] '
          '[--cwd DIR] [--store FILE] [--resume SESSION] [--sessions]');
      exitCode = 64;
      return;
    }
  }
  final writer = const IoShellWriter();
  if (listOnly) {
    if (storePath == null) {
      stderr.writeln('tina: --sessions needs --store FILE');
      exitCode = 64;
      return;
    }
    try {
      listSessions(writer: writer, storePath: storePath);
    } catch (e) {
      stderr.writeln('tina: $e');
      exitCode = 66;
    }
    return;
  }
  if (sessionId != null && storePath == null) {
    stderr.writeln('tina: --resume needs --store FILE');
    exitCode = 64;
    return;
  }
  try {
    final shell = Shell.start(
      writer: writer,
      options: ShellOptions(
        configPath: configPath,
        workingDirectory: workingDirectory,
        storePath: storePath,
        sessionId: sessionId,
      ),
    );
    await runShell(
      shell: shell,
      readLine: () async => stdin.readLineSync(),
    );
    shell.host.close();
  } catch (e) {
    stderr.writeln('tina: $e');
    exitCode = 66;
  }
}
