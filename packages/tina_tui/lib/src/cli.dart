import 'dart:io';
import 'dart:async';
import 'package:tina_goals/tina_goals.dart';
import 'package:tina_engine_2/tina_engine_2.dart' show StopReason;
import 'package:tina_persistence/tina_persistence.dart';
import 'app.dart';
import 'tui_session.dart';
import 'shell_completion.dart';
import 'session_selection.dart';
import 'restart.dart';

const cliHelp =
    '''usage: tina [--config FILE] [--cwd DIR] [--store FILE] [--resume [ID] | --continue]
            [--model PROVIDER/MODEL] [--models [PROVIDER]] [--prompt TEXT|-]
            [--goal TEXT [--max-goal-turns N]]
            [--configure] [--version] [--completion bash|zsh|fish]
            [--backend ansi|notcurses] [--no-sandbox]
            [--import-sessions PATH [--dry-run]]

Starts the engine2 terminal app. /help lists loaded commands.
--backend notcurses enables inline images; ANSI is the default text renderer.
--no-sandbox disables OS filesystem and network confinement for this run.
Permission modes and approval checks still apply; child environments remain filtered.
--model overrides the model for this run; resume otherwise restores its saved model.
--models prints available models without starting a session.
--prompt runs one turn without the TUI; use - to read the prompt from stdin.
--goal runs until its judge reports success; --max-goal-turns optionally bounds it.
Headless approval requests are denied; the permission mode is never escalated.
--configure edits global provider, model, plugin and request settings.
--resume shows saved sessions: Up/Down selects, Enter resumes, Escape cancels.
Rows show last saved time and a short preview; --resume ID reopens it directly.
--continue (-c) reopens the most recently updated main session in the workspace store.
--import-sessions converts a legacy session root, directory, manifest or JSONL
file into --store (default: the current workspace store). --dry-run writes nothing.
Each imported conversation gets its own ID, printed for --resume. Sources stay unchanged.
''';

Future<int> runCli(List<String> args,
    {String version = '0.0.0',
    String? Function() locateTerminalDevice = terminalDevicePath}) async {
  String? configPath;
  String? model;
  var backend = 'ansi';
  var osSandbox = true;
  String? prompt;
  String? goal;
  int? maxGoalTurns;
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
    if (a == '--backend' && i + 1 < args.length) {
      backend = args[++i];
      if (backend != 'ansi' && backend != 'notcurses') {
        stderr.writeln('tina: --backend must be ansi or notcurses');
        return 64;
      }
    } else if (a == '--no-sandbox') {
      osSandbox = false;
    } else if (a == '--model' && i + 1 < args.length) {
      model = args[++i];
    } else if (a == '--goal' && i + 1 < args.length) {
      goal = args[++i];
    } else if (a == '--max-goal-turns' && i + 1 < args.length) {
      maxGoalTurns = int.tryParse(args[++i]);
      if (maxGoalTurns == null || maxGoalTurns < 1) {
        stderr.writeln('tina: --max-goal-turns requires a positive integer');
        return 64;
      }
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
  final headless = prompt != null || goal != null;
  if ((maxGoalTurns != null && goal == null) ||
      (goal != null &&
          (goal.trim().isEmpty || goal.trim().length > goalMaxTextLength))) {
    stderr.writeln(
        'tina: --goal must be 1–$goalMaxTextLength characters; --max-goal-turns requires --goal');
    return 64;
  }
  if (!Directory(workingDirectory).existsSync()) {
    stderr.writeln('tina: workspace does not exist: $workingDirectory');
    return 66;
  }
  if ((headless && (configure || legacySource != null || listModels)) ||
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
  // Capture restart state before a startup picker, configuration editor or
  // native backend can take ownership of stdin. Missing pathname information
  // affects only automatic restart, never an otherwise usable terminal.
  final terminalDevice =
      !headless && stdin.hasTerminal ? locateTerminalDevice() : null;
  StartupTerminal? startup;
  if (continueLatest || (resume && sessionId == null)) {
    try {
      final sessions = resumableSessions(
          storePath ?? defaultSessionStorePath(workingDirectory));
      if (sessions.isEmpty) {
        stderr.writeln('tina: no main sessions to resume');
        return 66;
      }
      if (continueLatest) {
        sessionId = sessions.first.id;
      } else if (!headless && stdin.hasTerminal && stdout.hasTerminal) {
        startup = StartupTerminal.open(backend: backend);
        sessionId = await startup.pickSession(sessions);
      } else {
        sessionId = pickSession(sessions,
            readLine: stdin.readLineSync, writeLine: stdout.writeln);
      }
      if (sessionId == null) {
        startup?.close();
        return 0;
      }
    } catch (e) {
      startup?.close();
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
      final saved =
          await runConfigEditor(path, backend: backend, startup: startup);
      stdout.writeln(
          saved ? 'Settings saved. Run tina to start.' : 'Settings unchanged.');
      return 0;
    }
    // Assemble the session with a buffered terminal shared by its plugins.
    String? restartRoot;
    String? restartSession;
    final assembly = TuiAssembly.start(
      options: AssemblyOptions(
        configPath: configPath,
        version: version,
        workingDirectory: workingDirectory,
        storePath: storePath,
        sessionId: sessionId,
        model: model,
        osSandbox: osSandbox,
        approvalChannel: headless ? 'tina/approvals-stream' : null,
        onRestart: headless
            ? null
            : (root, id) {
                restartRoot = root;
                restartSession = id;
              },
      ),
    );

    if (headless) {
      try {
        final text = prompt ?? goal!;
        final interrupted = Completer<void>();
        final interruption = ProcessSignal.sigint.watch().listen((_) {
          assembly.host.session.loop.cancel('interrupt');
          if (!interrupted.isCompleted) interrupted.complete();
        });
        try {
          if (goal != null) {
            final owner =
                assembly.host.plugins.whereType<GoalsPlugin>().firstOrNull;
            if (owner == null) {
              stderr.writeln('tina: --goal requires tina/goals');
              return 78;
            }
            var cancelled = false;
            final achieved = await Future.any([
              owner.runToGoal(
                  text: goal,
                  initialPrompt: text,
                  maxTurns: maxGoalTurns,
                  send: (line) => assembly.host.send(line),
                  onTurn: (outcome) {
                    final reply = assembly.host.session.lastReply;
                    if (reply != null && reply.isNotEmpty)
                      stdout.writeln(reply);
                    if (outcome.stopReason != StopReason.complete) {
                      cancelled = outcome.stopReason == StopReason.cancelled;
                      stderr.writeln(outcome.detail);
                    }
                  }),
              interrupted.future.then((_) {
                cancelled = true;
                return false;
              }),
            ]);
            if (!achieved && !cancelled)
              stderr.writeln(
                  'tina: goal was not achieved or completion could not be verified');
            return achieved
                ? 0
                : cancelled
                    ? 130
                    : 1;
          }
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
    final result = await runApp(session, backend: backend, startup: startup);
    if (restartRoot == null) return result;
    // runApp has flushed session stores and restored terminal modes.
    if (terminalDevice == null) {
      stderr.writeln('tina: update installed; automatic restart could not '
          'find the terminal device. Run tina --continue to reopen it.');
      return result;
    }
    return await restartInTerminal(
        '$restartRoot/bin/tina',
        [
          '--cwd',
          workingDirectory,
          '--config',
          path,
          '--backend',
          backend,
          if (!osSandbox) '--no-sandbox',
          if (storePath != null) ...['--store', storePath],
          if (restartSession != null) ...['--resume', restartSession!],
        ],
        terminalDevice: terminalDevice);
  } catch (e) {
    startup?.close();
    stderr.writeln('tina: $e');
    return 66;
  } finally {
    startup?.close();
  }
}
