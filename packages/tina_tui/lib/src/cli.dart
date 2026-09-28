import 'dart:io';
import 'app.dart';
import 'tui_session.dart';
import 'shell_completion.dart';

const cliHelp =
    '''usage: tina [--config FILE] [--cwd DIR] [--store FILE] [--resume ID]
            [--sessions] [--configure] [--version] [--completion bash|zsh|fish]

Starts the engine2 terminal app. /help lists loaded commands.
--configure edits global provider, model, plugin and request settings.
--sessions lists sessions in the new workspace store; --resume ID reopens one.
Legacy sessions are preserved but cannot be loaded by this app.
''';

Future<int> runCli(List<String> args, {String version = '0.0.0'}) async {
  String? configPath;
  String? storePath;
  String? sessionId;
  var listOnly = false;
  var configure = false;
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
    } else if (a == '--configure') {
      configure = true;
    } else if (a == '--version' || a == '-v') {
      stdout.writeln('tina $version (engine2)');
      return 0;
    } else if (a == '--completion' && i + 1 < args.length) {
      try {
        stdout.writeln(shellCompletion(args[++i]));
        return 0;
      } on FormatException catch (e) {
        stderr.writeln(e.message);
        return 64;
      }
    } else if (a == '--help' || a == '-h') {
      stdout.writeln(cliHelp);
      return 0;
    } else {
      stderr.writeln('unknown or incomplete argument: $a');
      stderr.writeln(cliHelp);
      return 64;
    }
  }
  if (!Directory(workingDirectory).existsSync()) {
    stderr.writeln('tina: workspace does not exist: $workingDirectory');
    return 66;
  }
  if ((listOnly && (sessionId != null || configure)) ||
      (configure && sessionId != null)) {
    stderr.writeln(
        'tina: --sessions, --resume and --configure are mutually exclusive');
    return 64;
  }

  if (listOnly) {
    try {
      listSessions(
        writer: StdoutAssemblyWriter(),
        storePath: storePath ?? defaultSessionStorePath(workingDirectory),
      );
    } catch (e) {
      stderr.writeln('tina: $e');
      return 66;
    }
    return 0;
  }
  try {
    final path = configPath ?? defaultConfigPath();
    if (configure || !File(path).existsSync()) {
      if (!stdin.hasTerminal || !stdout.hasTerminal) {
        stderr.writeln(
            'tina: configure a provider and model in $path, or run tina --configure in a terminal');
        return 78;
      }
      final saved = await runConfigEditor(path);
      stdout.writeln(
          saved ? 'Settings saved. Run tina to start.' : 'Settings unchanged.');
      return 0;
    }
    // Assemble the session with a buffered terminal shared by its plugins.
    final assembly = TuiAssembly.start(
      options: AssemblyOptions(
        configPath: configPath,
        version: version,
        workingDirectory: workingDirectory,
        storePath: storePath,
        sessionId: sessionId,
      ),
    );

    // Attach the renderer and approval dialog to the assembled session.
    final session = TuiSession.wrap(assembly);
    return await runApp(session);
  } catch (e) {
    stderr.writeln('tina: $e');
    return 66;
  }
}
