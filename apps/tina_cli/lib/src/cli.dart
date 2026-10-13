import 'dart:io';
import 'dart:async';
import 'package:tina_host/tina_host.dart';
import 'package:tina_providers/tina_providers.dart';
import 'package:tina_tools/tina_tools.dart' show noSandboxOption;
import 'cli_options.dart';
import 'plugin_catalog.dart';
import 'package:tina_persistence/tina_persistence.dart';
import 'package:tina_tui/tina_tui.dart';
import 'package:tina/tui.dart';
import 'shell_completion.dart';
import 'restart.dart';
import 'session_selection.dart';

String get cliHelp => applicationCliSchema().help;

Future<int> runCli(
  List<String> args, {
  String version = '0.0.0',
  AssemblyDiagnostics? diagnostics,
  void Function(PluginRegistry<SessionPluginContext>)? registerPlugins,
  Future<String> Function()? readStdin,
  String? Function() locateTerminalDevice = terminalDevicePath,
}) async {
  final registry = firstPartyPlugins();
  registerPlugins?.call(registry);
  final schema = applicationCliSchema(registry: registry);
  final CliArguments parsed;
  final ({String owner, CliSessionCommand command})? selected;
  try {
    parsed = schema.parse(args);
    if (parsed.contains(versionOption)) {
      stdout.writeln('tina $version (engine2)');
      return 0;
    }
    if (parsed[completionOption] case final shell?) {
      stdout.writeln(shellCompletion(shell, schema: schema));
      return 0;
    }
    if (parsed.contains(helpOption)) {
      stdout.writeln(schema.help);
      return 0;
    }
    schema.validate(parsed);
    selected = schema.sessionCommand(parsed);
  } on FormatException catch (e) {
    stderr.writeln('tina: ${e.message}');
    stderr.writeln(schema.help);
    return 64;
  }
  final configPath = parsed[configOption];
  final model = parsed[modelOption];
  final backend = parsed[backendOption] ?? 'auto';
  final osSandbox = !parsed.contains(noSandboxOption);
  final listProvider = parsed[modelsOption];
  final listModels = parsed.contains(modelsOption);
  final storePath = parsed[storeOption];
  var sessionId = parsed[resumeOption];
  final resume = parsed.contains(resumeOption);
  final continueLatest = parsed.contains(continueOption);
  final configure = parsed.contains(configureOption);
  final legacySource = parsed[importSessionsOption];
  final dryRun = parsed.contains(dryRunOption);
  final workingDirectory = parsed[cwdOption] ?? Directory.current.path;
  final command = selected?.command;
  final headless = command != null;
  if (!Directory(workingDirectory).existsSync()) {
    stderr.writeln('tina: workspace does not exist: $workingDirectory');
    return 66;
  }
  if (headless && (configure || legacySource != null || listModels)) {
    stderr.writeln(
      'tina: ${command.option.flag} cannot be combined with '
      '--configure, --import-sessions or --models',
    );
    return 64;
  }
  if (listModels &&
      (resume || continueLatest || configure || legacySource != null)) {
    stderr.writeln(
      'tina: --models cannot configure, import or resume a session',
    );
    return 64;
  }
  if ([
            resume,
            continueLatest,
            configure,
            legacySource != null,
          ].where((v) => v).length >
          1 ||
      (dryRun && legacySource == null)) {
    stderr.writeln(
      'tina: --continue, --resume, --configure and --import-sessions are mutually exclusive; --dry-run requires --import-sessions',
    );
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
      final results = const LegacySessionImporter().importPath(
        legacySource,
        store: store,
      );
      for (final result in results) {
        stdout.writeln(
          '${result.status.name}: ${result.id ?? result.source}'
          '${result.active ? ' (legacy active conversation)' : ''}'
          ' — ${result.messages} source messages',
        );
        if (result.error != null) stderr.writeln('  ${result.error}');
        for (final warning in result.warnings) {
          stdout.writeln('  $warning');
        }
      }
      stdout.writeln(
        'Import ${dryRun ? 'preview' : 'finished'}: '
        '${results.where((r) => r.status == LegacyImportStatus.imported || r.status == LegacyImportStatus.ready).length} '
        '${dryRun ? 'ready' : 'imported'}, '
        '${results.where((r) => r.status == LegacyImportStatus.skipped).length} skipped, '
        '${results.where((r) => r.status == LegacyImportStatus.failed).length} failed.',
      );
      return results.any((r) => r.status == LegacyImportStatus.failed) ? 65 : 0;
    } catch (e) {
      stderr.writeln('tina: $e');
      return 65;
    } finally {
      store?.close();
    }
  }

  if (command?.readsStdin == true && resume && sessionId == null) {
    stderr.writeln(
      'tina: use --continue or --resume ID when reading ${command!.option.flag} from stdin',
    );
    return 64;
  }
  // Capture restart state before a startup picker, configuration editor or
  // native backend can take ownership of stdin. Missing pathname information
  // affects only automatic restart, never an otherwise usable terminal.
  final terminalDevice = !headless && stdin.hasTerminal
      ? locateTerminalDevice()
      : null;
  StartupTerminal? startup;
  if (continueLatest || (resume && sessionId == null)) {
    try {
      final sessions = resumableSessions(
        storePath ?? defaultSessionStorePath(workingDirectory),
      );
      if (sessions.isEmpty) {
        stderr.writeln('tina: no main sessions to resume');
        return 66;
      }
      if (continueLatest) {
        sessionId = sessions.first.id;
      } else if (!headless && stdin.hasTerminal && stdout.hasTerminal) {
        startup = StartupTerminal.open(backend: backend);
        sessionId = await startup.pickSession(sessionChoices(sessions));
      } else {
        sessionId = pickSession(
          sessionChoices(sessions),
          readLine: stdin.readLineSync,
          writeLine: stdout.writeln,
        );
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
    Map<String, Object?> operationArguments = const {};
    try {
      operationArguments =
          await command?.prepare.call(
            readStdin ?? () => stdin.transform(systemEncoding.decoder).join(),
          ) ??
          const {};
    } on FormatException catch (e) {
      stderr.writeln('tina: ${e.message}');
      return 64;
    }
    final path = configPath ?? defaultConfigPath();
    if (listModels) {
      final loaded = loadTinaConfig(path: path);
      if (loaded is TinaConfigProblem) throw FormatException(loaded.problem);
      for (final descriptor in loaded.config.descriptors) {
        if (listProvider != null && descriptor.id != listProvider) continue;
        for (final name in descriptor.models.keys) {
          if (!(loaded.config.providers[descriptor.id]?.disabledModels.contains(
                name,
              ) ??
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
          'tina: configure a provider and model in $path, or run tina --configure in a terminal',
        );
        return 78;
      }
      final saved = await runConfigEditor(
        path,
        backend: backend,
        startup: startup,
      );
      stdout.writeln(
        saved ? 'Settings saved. Run tina to start.' : 'Settings unchanged.',
      );
      return 0;
    }
    // Assemble the session with a buffered terminal shared by its plugins.
    String? restartRoot;
    String? restartSession;
    final assembly = SessionAssembly.start(
      diagnostics: diagnostics,
      // Reuse the declarations that supplied parsing/help, without calling
      // extension registration a second time during assembly.
      registerPlugins: (target) {
        for (final id in registry.ids.where((id) => !id.startsWith('tina/'))) {
          target.registerDefinition(registry.definition(id));
        }
      },
      options: AssemblyOptions(
        configPath: configPath,
        version: version,
        workingDirectory: workingDirectory,
        storePath: storePath,
        sessionId: sessionId,
        model: model,
        osSandbox: osSandbox,
        interactive: !headless,
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
      final connection = assembly.host.connect();
      try {
        final id = connection.requestWindow.id('cli');
        final request = connection.submitOperation(
          selected!.owner,
          command.operation,
          arguments: operationArguments,
          id: id,
        );
        var afterSeq = -1;
        void drainOutput() {
          final page = connection.output(id, afterSeq: afterSeq);
          if (page.missed)
            stderr.writeln('tina: some operation output expired');
          for (final entry in page.entries) {
            (entry.error ? stderr : stdout).writeln(entry.text);
            if (entry.truncated)
              stderr.writeln('tina: operation output truncated');
          }
          afterSeq = page.throughSeq;
        }

        final release = connection.listen((_) => drainOutput());
        final interruption = ProcessSignal.sigint.watch().listen((_) {
          final workId = request.snapshot.workId;
          if (workId != null) connection.cancel([workId], reason: 'interrupt');
        });
        try {
          final result = await request.completed;
          drainOutput();
          final notice = result.result?.notice;
          if (notice != null) stderr.writeln('tina: $notice');
          return switch (result.state) {
            SessionRequestState.completed => 0,
            SessionRequestState.cancelled => 130,
            SessionRequestState.rejected => 78,
            _ => 1,
          };
        } finally {
          release();
          await interruption.cancel();
        }
      } finally {
        connection.close();
        await assembly.shutdown();
      }
    }

    // Attach the renderer and approval dialog to the assembled session.
    final session = TuiSession.wrap(assembly);
    final int result;
    try {
      result = await runTui(session, backend: backend, startup: startup);
    } finally {
      // Native startup can fail before runApp installs its teardown. Release
      // the already assembled plugins/provider and configuration watcher too.
      await session.shutdown();
    }
    if (restartRoot == null) return result;
    // runApp has flushed session stores and restored terminal modes.
    if (terminalDevice == null) {
      stderr.writeln(
        'tina: update installed; automatic restart could not '
        'find the terminal device. Run tina --continue to reopen it.',
      );
      return result;
    }
    return await restartInTerminal('$restartRoot/bin/tina', [
      '--cwd',
      workingDirectory,
      '--config',
      path,
      '--backend',
      backend,
      if (!osSandbox) '--no-sandbox',
      if (storePath != null) ...['--store', storePath],
      if (restartSession != null) ...['--resume', restartSession!],
    ], terminalDevice: terminalDevice);
  } catch (e) {
    startup?.close();
    stderr.writeln('tina: $e');
    return 66;
  } finally {
    startup?.close();
  }
}
