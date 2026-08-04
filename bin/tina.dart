import 'dart:async';
import 'dart:io';

import 'package:tina/composition/agent_composition.dart';
import 'package:tina/composition/app_composition.dart';
import 'package:tina/config.dart';
import 'package:tina/config/setup.dart';
import 'package:tina/config/user_config.dart';
import 'package:tina/composition/config_providers.dart';
import 'package:tina/logging.dart';
import 'package:tina/platform/environment.dart';
import 'package:tina/session_commands/session_command_handlers.dart';
import 'package:tina/summaries/summary_index.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina/project/project_trust.dart';
import 'package:tina/tui_coordinator.dart';
import 'package:logging/logging.dart';

final _log = Logger('tina.cli');

Future<void> main(List<String> argv) async {
  final environment = const PlatformEnvironment();

  // Reap tracked subprocesses when killed externally so a backgrounded command
  // (e.g. `npm run dev &`) can't outlive tina. SIGINT is handled in the TUI
  // (graceful quit → the finally below); SIGTERM/SIGHUP otherwise default-
  // terminate without cleanup, so we intercept them to reap first.
  _installShutdownReaper();

  // Non-tty (piped/CI) first run: the stdin wizard, before the TUI. A real
  // terminal uses the in-TUI overlay instead (driven by setupMode below).
  if (_shouldRunStdinSetup(argv, environment)) {
    final reg = builtinRegistry(env: environment.env);
    _attachModelsDevCatalog(reg, environment.env);
    runSetupWizard(env: environment.env, registry: reg);
  }

  try {
    while (true) {
      // Layer the persistent user config (~/.tina/config) under the real env:
      // its per-provider keys/base URLs become a synthetic env overlay so they
      // reach every agent — the registry's authFor scan serves the startup
      // provider AND sub-agents, who resolve keys without the startup override.
      // The default provider/model and tiers travel as a UserConfig into parse.
      final userConfig = loadUserConfig(env: environment.env);
      final mergedEnv = {...environment.env, ...buildEnvOverlay(userConfig)};
      final registry = builtinRegistry(env: mergedEnv);
      registerConfigProviders(registry, userConfig);
      _attachModelsDevCatalog(registry, environment.env);

      final Config config;
      try {
        config = Config.parse(argv,
            env: mergedEnv, registry: registry, userConfig: userConfig);
      } on FormatException catch (e) {
        stderr.writeln(e.message);
        exit(64);
      }
      if (config.showHelp) {
        stdout.writeln(Config.usage);
        return;
      }
      if (config.initConfig) {
        writeConfigTemplate(env: environment.env);
        return;
      }
      if (config.listSessions) {
        await _listSessions();
        return;
      }

      // Project-trust gate: decide once, before any agent is built, whether this
      // cwd's AGENTS.md may enter system prompts. Withholds it for an untrusted
      // project (headless skips, TUI asks on the tty before the TUI takes over)
      // unless --trust / [trust] default override. Stored on the shared pipeline
      // so every agent (main, sub, /spawn) honors the same decision.
      defaultPipeline.loadProjectContext =
          await _resolveProjectTrust(config, mergedEnv);

      final app = await buildAppComposition(config: config, registry: registry);

      // Logging inits after config parses (so a parse error still goes to the
      // pre-logging stderr path) and before any service runs. Idempotent, so a
      // relaunch after setup re-enters harmlessly. Verbose via --verbose or the
      // existing COCOON_DEBUG=1 convention; mirror to stderr when non-interactive.
      initLogging(
        level: (config.verbose || environment.env['COCOON_DEBUG'] == '1')
            ? Level.FINE
            : Level.INFO,
        mirrorToStderr: config.nonInteractive,
      );

      if (config.nonInteractive) {
        await _runNonInteractive(app);
        return;
      }

      // Setup mode = forced (--setup) or unconfigured on a tty (no resolvable
      // key for the default provider). The overlay collects config and writes
      // ~/.tina/config; on setupWrote we loop to re-parse + re-launch with it.
      final isTty = stdioType(stdin) == StdioType.terminal;
      final setupMode = config.setup || (config.apiKey.isEmpty && isTty);
      final outcome = await _runInteractive(app, setupMode: setupMode);
      if (outcome == RunOutcome.setupWrote) continue; // relaunch
      if (outcome == RunOutcome.setupCancelled) {
        stderr.writeln(
            'Setup cancelled. Re-run with --setup or set ANTHROPIC_API_KEY.');
      }
      return;
    }
    // Unreachable — the loop only exits via return.
  } on BackendUnavailableError catch (e) {
    // Explicit backend couldn't init — quit nonzero with a clean message.
    stderr.writeln(e.message);
    exit(1);
  } finally {
    // Reap any tool subprocess still alive (a leaked backgrounded child), then
    // close logging. Covers every normal exit path (interactive /quit, headless
    // completion, setup relaunch).
    await ChildProcessRegistry.instance.reapAll();
    await closeLogging();
    exit(0);
  }
}

/// Intercept SIGTERM/SIGHUP: reap tracked subprocesses, then exit nonzero. Once
/// a signal is watched it no longer auto-terminates the process, so the handler
/// must always exit.
void _installShutdownReaper() {
  for (final signal in const [ProcessSignal.sigterm, ProcessSignal.sighup]) {
    signal.watch().listen((_) async {
      try {
        await ChildProcessRegistry.instance.reapAll();
      } catch (e, st) {
        _log.warning('shutdown reap failed', e, st);
      }
      exit(1);
    });
  }
}

Future<RunOutcome> _runInteractive(AppComposition app,
    {bool setupMode = false}) async {
  final coordinator = await TuiCoordinator.create(app: app);
  final result = await coordinator.run(setupMode: setupMode);
  return result;
}

Future<void> _runNonInteractive(AppComposition app) async {
  // HeadlessHost is a UI-agnostic HostInterface: agent prose and tool lifecycle
  // to stdout, notices to stderr, and permission `ask`s refused with a flag
  // hint. Wiring it as both `sink` and `asker` keeps bin/ free of any terminal
  // type — no Screen, ChatRegion, or Spinner reaches the non-interactive path.
  final host = HeadlessHost();

  // `/index` headless: run the staleness dance directly (no agent turn). The
  // summary fleet runs via SummaryIndex.refresh (its own ephemeral composition),
  // so the non-interactive agent isn't needed — the dance's notices stream to
  // the HeadlessHost (stdout/stderr). confirm is null (no interactive input),
  // so the up-to-date branch reports and stops, matching the deleted bin's
  // `--dry-run` behavior.
  final prompt = app.config.prompt?.trim() ?? '';
  if (prompt == '/index') {
    final idx = SummaryIndex(
      config: app.config,
      registry: app.registry,
      environment: app.environment,
      projectRoot: Directory.current.path,
    );
    try {
      await runIndexDance(host: host, summaryIndex: idx, confirm: null);
    } finally {
      await host.dispose();
      app.provider.close();
      await closeLogging();
    }
    return;
  }

  // The headless agent runs one turn with the base tools and the un-widened
  // policy — withSubAgents: false preserves the pre-composition behavior (a
  // non-interactive run does not gain delegate/channel tools).
  final agent = buildAgent(
    pipeline: app.pipeline,
    scheduler: app.scheduler,
    conversationId: app.initialConversationId,
    provider: app.provider,
    host: host,
    policy: app.policy,
    config: app.config,
    withSubAgents: false,
  );

  final history = app.initialHistory;
  final recorder = SessionRecorder(
    app.store,
    app.initialSessionId,
    app.initialConversationId,
    providerId: app.config.provider,
    baseUrl: app.config.baseUrl,
  );
  final preLen = history.length;

  try {
    await agent.run(
      history: history,
      userInput: app.config.prompt!,
    );
  } finally {
    for (final m in history.skip(preLen)) {
      try {
        await recorder.append(m);
      } catch (e, st) {
        _log.severe('session write failed', e, st);
        break;
      }
    }
    // Non-interactive hint goes to stderr so callers parsing stdout for the
    // agent's answer aren't disrupted.
    if (app.initialSessionId.isNotEmpty) {
      stderr.writeln(
          'session: ${app.initialSessionId}  (resume: tina --resume ${app.initialSessionId})');
    }
    await host.dispose();
    await app.store.close();
    app.provider.close();
    await closeLogging();
  }
}

/// Whether to run the first-run setup wizard over **stdin** — the non-tty
/// (piped/CI) path. A real terminal is handled by the in-TUI overlay instead
/// (see the `setupMode` branch in `main`). `--help` / `--init-config` /
/// `--list` / `--prompt` short-circuit without setup; `--setup` forces it;
/// otherwise it runs only when stdin is NOT a terminal and no config exists.
bool _shouldRunStdinSetup(List<String> argv, Environment environment) {
  if (stdioType(stdin) == StdioType.terminal) return false; // tty → overlay
  final nonInteractive = argv.any((a) =>
      a == '--prompt' ||
      a.startsWith('--prompt=') ||
      a == '--help' ||
      a == '-h' ||
      a == '--list' ||
      a == '-l' ||
      a == '--init-config');
  if (nonInteractive) return false;
  if (argv.any((a) => a == '--setup')) return true;
  return !userConfigFile(environment.env).existsSync();
}

/// Print every saved session to stdout in the same format `/sessions` uses
/// inside the TUI, then return. Lightweight: only constructs the on-disk store,
/// no provider or TUI.
Future<void> _listSessions() async {
  final store = JsonlSessionStore.defaultLocation();
  try {
    final sessions = await store.listSessions();
    if (sessions.isEmpty) {
      stdout.writeln('(no saved sessions)');
      return;
    }
    for (final s in sessions) {
      final stamp = _shortStamp(s.updatedAt);
      stdout.writeln('${s.id}  $stamp  ${s.messageCount}msg  ${s.title}');
    }
  } finally {
    await store.close();
  }
}

String _shortStamp(DateTime t) {
  final l = t.toLocal();
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${pad(l.month)}-${pad(l.day)} '
      '${pad(l.hour)}:${pad(l.minute)}';
}

/// Attach a [ModelsDevCatalog] to [registry] and kick off a non-blocking
/// load. `COCOON_MODELS_DEV=0` skips the fetch (handy for tests and
/// hermetic CI). The catalog fetch is fire-and-forget; the compiled
/// descriptor maps are the source of truth until it completes, so the
/// `/settings` picker and bare-model resolution never block on the
/// network.
void _attachModelsDevCatalog(
    ProviderRegistry registry, Map<String, String> env) {
  if (env['COCOON_MODELS_DEV'] == '0') return;
  final catalog = ModelsDevCatalog(env: env);
  registry.catalog = catalog;
  // Errors are logged inside the catalog at FINE; we don't want a network
  // miss to surface in the user-facing log stream.
  unawaited(catalog.load().catchError((Object _) {}));
}

/// Resolve whether the launch cwd's project context (AGENTS.md) may be loaded.
/// Headless / non-tty runs skip it for an untrusted project (no UI to ask); a
/// tty run prompts on stdin before the TUI takes over the terminal — the same
/// pre-TUI stdin window the setup wizard uses.
Future<bool> _resolveProjectTrust(Config config, Map<String, String> env) async {
  final hasUi = !config.nonInteractive &&
      stdioType(stdin) == StdioType.terminal;
  return resolveProjectTrust(
    cwd: Directory.current.path,
    store: ProjectTrustStore.forTinaDir(tinaDirFromEnv(env)),
    hasUi: hasUi,
    defaultMode: config.trustDefault,
    override: config.trustOverride,
    ask: hasUi ? _askTrustStdin : null,
  );
}

/// Plain stdin trust prompt (used before the notcurses TUI starts). Yes
/// persists the decision so the project isn't re-asked on the next launch.
Future<bool> _askTrustStdin(String cwd) async {
  stdout
    ..writeln('Trust this project?')
    ..writeln('  $cwd')
    ..writeln('  An AGENTS.md here can inject instructions into the agent. '
        'Trusting loads it.')
    ..write('Load it? [y/N] ');
  final line = stdin.readLineSync()?.trim().toLowerCase() ?? '';
  return line == 'y' || line == 'yes';
}
