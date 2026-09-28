import 'dart:io';
import 'package:tina_persistence/tina_persistence.dart';
import 'app.dart';
import 'tui_session.dart';
import 'shell_completion.dart';

const cliHelp =
    '''usage: tina [--config FILE] [--cwd DIR] [--store FILE] [--resume ID]
            [--sessions] [--configure] [--version] [--completion bash|zsh|fish]
            [--import-sessions PATH [--dry-run]]

Starts the engine2 terminal app. /help lists loaded commands.
--configure edits global provider, model, plugin and request settings.
--sessions lists sessions in the new workspace store; --resume ID reopens one.
--import-sessions converts a legacy session root, directory, manifest or JSONL
file into --store (default: the current workspace store). --dry-run writes nothing.
Each imported conversation gets its own ID, printed for --resume. Sources stay unchanged.
''';

Future<int> runCli(List<String> args, {String version = '0.0.0'}) async {
  String? configPath;
  String? storePath;
  String? sessionId;
  var listOnly = false;
  var configure = false;
  String? legacySource;
  var dryRun = false;
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
    } else if (a == '--import-sessions' && i + 1 < args.length) {
      legacySource = args[++i];
    } else if (a == '--dry-run') {
      dryRun = true;
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
  if ([listOnly, sessionId != null, configure, legacySource != null]
              .where((v) => v)
              .length >
          1 ||
      (dryRun && legacySource == null)) {
    stderr.writeln(
        'tina: --sessions, --resume, --configure and --import-sessions are mutually exclusive; --dry-run requires --import-sessions');
    return 64;
  }

  if (legacySource != null) {
    SessionStore? store;
    try {
      if (!dryRun) {
        final path = storePath ?? defaultSessionStorePath(workingDirectory);
        File(path).parent.createSync(recursive: true);
        store = SessionStore.open(path);
      }
      final results =
          const LegacySessionImporter().importPath(legacySource, store: store);
      for (final result in results) {
        stdout.writeln('${result.status.name}: ${result.id ?? result.source}'
            '${result.active ? ' (legacy active conversation)' : ''}'
            ' — ${result.messages} source messages');
        if (result.error != null) stderr.writeln('  ${result.error}');
        for (final warning in result.warnings) {
          stdout.writeln('  $warning');
        }
      }
      stdout.writeln('Import ${dryRun ? 'preview' : 'finished'}: '
          '${results.where((r) => r.status == LegacyImportStatus.imported || r.status == LegacyImportStatus.ready).length} '
          '${dryRun ? 'ready' : 'imported'}, '
          '${results.where((r) => r.status == LegacyImportStatus.skipped).length} skipped, '
          '${results.where((r) => r.status == LegacyImportStatus.failed).length} failed.');
      return results.any((r) => r.status == LegacyImportStatus.failed) ? 65 : 0;
    } catch (e) {
      stderr.writeln('tina: $e');
      return 65;
    } finally {
      store?.close();
    }
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
