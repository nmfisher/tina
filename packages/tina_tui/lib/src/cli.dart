import 'dart:io';
import 'package:tina_engine_2/tina_engine_2.dart' show StopReason;
import 'package:tina_persistence/tina_persistence.dart';
import 'app.dart';
import 'tui_session.dart';
import 'shell_completion.dart';
import 'session_selection.dart';

const cliHelp =
    '''usage: tina [--config FILE] [--cwd DIR] [--store FILE] [--resume [ID] | --continue]
            [--model PROVIDER/MODEL] [--models [PROVIDER]] [--prompt TEXT|-]
            [--configure] [--version] [--completion bash|zsh|fish]
            [--import-sessions PATH [--dry-run]]

Starts the engine2 terminal app. /help lists loaded commands.
--model overrides the model for this run; resume otherwise restores its saved model.
--models prints available models without starting a session.
--prompt runs one turn without the TUI; use - to read the prompt from stdin.
Headless approval requests are denied; the permission mode is never escalated.
--configure edits global provider, model, plugin and request settings.
--resume lists main sessions and lets you select one; --resume ID reopens it directly.
--continue (-c) reopens the most recently updated main session in the workspace store.
--import-sessions converts a legacy session root, directory, manifest or JSONL
file into --store (default: the current workspace store). --dry-run writes nothing.
Each imported conversation gets its own ID, printed for --resume. Sources stay unchanged.
''';

Future<int> runCli(List<String> args, {String version = '0.0.0'}) async {
  String? configPath;
  String? model;
  String? prompt;
  String? listProvider;
  var listModels = false;
  String? storePath;
  String? sessionId;
  var resume = false;
  var continueLatest = false;
  var configure = false;
  String? legacySource;
  var dryRun = false;
  var workingDirectory = Directory.current.path;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--model' && i + 1 < args.length) {
      model = args[++i];
    } else if (a == '--prompt' && i + 1 < args.length) {
      prompt = args[++i];
    } else if (a == '--models') {
      listModels = true;
      if (i + 1 < args.length && !args[i + 1].startsWith('-'))
        listProvider = args[++i];
    } else if (a == '--config' && i + 1 < args.length) {
      configPath = args[++i];
    } else if (a == '--cwd' && i + 1 < args.length) {
      workingDirectory = args[++i];
    } else if (a == '--store' && i + 1 < args.length) {
      storePath = args[++i];
    } else if (a == '--resume') {
      resume = true;
      if (i + 1 < args.length && !args[i + 1].startsWith('-')) {
        sessionId = args[++i];
      }
    } else if (a.startsWith('--resume=') && a.length > '--resume='.length) {
      resume = true;
      sessionId = a.substring('--resume='.length);
    } else if (a == '--continue' || a == '-c') {
      continueLatest = true;
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
  if ((prompt != null && (configure || legacySource != null || listModels)) ||
      (listModels &&
          (resume || continueLatest || configure || legacySource != null))) {
    stderr.writeln(
        'tina: --prompt and --models cannot be combined with configure or import; --models cannot resume a session');
    return 64;
  }
  if ([resume, continueLatest, configure, legacySource != null]
              .where((v) => v)
              .length >
          1 ||
      (dryRun && legacySource == null)) {
    stderr.writeln(
        'tina: --continue, --resume, --configure and --import-sessions are mutually exclusive; --dry-run requires --import-sessions');
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

  if (prompt == '-' && resume && sessionId == null) {
    stderr.writeln(
        'tina: use --continue or --resume ID when reading a prompt from stdin');
    return 64;
  }
  if (continueLatest || (resume && sessionId == null)) {
    try {
      final sessions = resumableSessions(
          storePath ?? defaultSessionStorePath(workingDirectory));
      if (sessions.isEmpty) {
        stderr.writeln('tina: no main sessions to resume');
        return 66;
      }
      sessionId = continueLatest
          ? sessions.first.id
          : pickSession(sessions,
              readLine: stdin.readLineSync, writeLine: stdout.writeln);
      if (sessionId == null) return 0;
    } catch (e) {
      stderr.writeln('tina: $e');
      return 66;
    }
  }
  try {
    if (prompt == '-')
      prompt = await stdin.transform(systemEncoding.decoder).join();
    if (prompt != null && prompt.trim().isEmpty) {
      stderr.writeln('tina: prompt is empty');
      return 64;
    }
    final path = configPath ?? defaultConfigPath();
    if (listModels) {
      final loaded = loadTinaConfig(path: path);
      if (loaded is TinaConfigProblem) throw FormatException(loaded.problem);
      for (final descriptor in loaded.config.descriptors) {
        if (listProvider != null && descriptor.id != listProvider) continue;
        for (final name in descriptor.models.keys) {
          if (!(loaded.config.providers[descriptor.id]?.disabledModels
                  .contains(name) ??
              false)) {
            stdout.writeln('${descriptor.id}/$name');
          }
        }
      }
      return 0;
    }
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
        model: model,
        approvalChannel: prompt == null ? null : 'tina/approvals-stream',
      ),
    );

    if (prompt != null) {
      try {
        final text = prompt;
        final interruption = ProcessSignal.sigint
            .watch()
            .listen((_) => assembly.host.session.loop.cancel('interrupt'));
        try {
          final outcome = await assembly.host.send(text);
          final reply = assembly.host.session.lastReply;
          if (reply != null && reply.isNotEmpty) stdout.writeln(reply);
          if (outcome.stopReason != StopReason.complete) {
            stderr.writeln(outcome.detail);
            return outcome.stopReason == StopReason.cancelled ? 130 : 1;
          }
          return 0;
        } finally {
          await interruption.cancel();
        }
      } finally {
        assembly.close();
      }
    }

    // Attach the renderer and approval dialog to the assembled session.
    final session = TuiSession.wrap(assembly);
    return await runApp(session);
  } catch (e) {
    stderr.writeln('tina: $e');
    return 66;
  }
}
