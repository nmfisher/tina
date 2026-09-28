import 'dart:io';

import 'package:tina_tui/tina_tui.dart';

/// The entry point is deliberately thin: parse flags, read the config,
/// build the assembly, hand the session to the full-screen render loop.
/// All decisions live in `lib/src/` where the tests drive them.
///
/// The order is the brief's order, and each step happens exactly once:
/// config → assembly → (the loop) terminal in services, approval dialog
/// as the sandbox's Approver, plugins already mounted by the assembly →
/// renderer. There is no REPL and no second entry point.
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
      stdout.writeln('usage: tina-tui [--config ~/.tina/config] '
          '[--cwd DIR] [--store FILE] [--resume SESSION] [--sessions]');
      return;
    } else {
      stdout.writeln('unknown argument: $a');
      stdout.writeln('usage: tina-tui [--config ~/.tina/config] '
          '[--cwd DIR] [--store FILE] [--resume SESSION] [--sessions]');
      exitCode = 64;
      return;
    }
  }

  if (listOnly) {
    if (storePath == null) {
      stderr.writeln('tina: --sessions needs --store FILE');
      exitCode = 64;
      return;
    }
    try {
      listSessions(
        writer: StdoutAssemblyWriter(),
        storePath: storePath,
      );
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
    // 1. The config, before anything is wired: its note becomes the
    //    first line of the conversation; its model reference rides in
    //    the assembly's config-driven provider factory.
    final config = loadTinaConfig(path: configPath);
    if (config.note != null) stdout.writeln(config.note);

    // 2. The assembly — engine, host, services, plugins, session. No
    //    terminal yet: the render loop owns that slot, and until it
    //    runs this thing is headless.
    final assembly = TuiAssembly.start(
      options: AssemblyOptions(
        configPath: configPath,
        workingDirectory: workingDirectory,
        storePath: storePath,
        sessionId: sessionId,
      ),
    );

    // 3. The app: session wrapper, then the loop — which registers the
    //    TUI's Terminal in the services locator and the approval dialog
    //    as the sandbox's Approver before its first paint, mounts
    //    nothing (the assembly already did), and runs the renderer.
    final session = TuiSession.wrap(assembly);
    exitCode = await runApp(session);
  } catch (e) {
    stderr.writeln('tina: $e');
    exitCode = 66;
  }
}
