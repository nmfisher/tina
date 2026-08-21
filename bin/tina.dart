import 'dart:async';
import 'dart:io';

import 'package:tina/composition/agent_composition.dart';
import 'package:tina/composition/app_composition.dart';
import 'package:tina/composition/edit_verifier.dart';
import 'package:tina/config.dart';
import 'package:tina/config/setup.dart';
import 'package:tina/config/user_config.dart';
import 'package:tina/composition/config_providers.dart';
import 'package:tina/logging.dart';
import 'package:tina/pipeline/default_workflow.dart';
import 'package:tina/pipeline/pipeline_runner.dart';
import 'package:tina/platform/environment.dart';
import 'package:tina/host/headless_watchdog.dart';
import 'package:tina/session_commands/session_command_handlers.dart';
import 'package:tina/persistence/session_restore.dart';
import 'package:tina/summaries/allocations_store.dart';
import 'package:tina/summaries/summary_index.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina/project/project_trust.dart';
import 'package:tina/tui_coordinator.dart';
import 'package:tina/version.g.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('tina.cli');

/// The per-session lock acquired on resume/continue, if any. Module-level so
/// the SIGTERM/SIGHUP reaper and the zone-guard crash path can release it
/// (synchronously) before exit — mirroring [_guardedScreen]. Normal exits
/// release it via the `finally` in [_run]. A leaked lock (catastrophic exit
/// with no cleanup) is reclaimed next start via its PID-liveness check.
SessionLock? _activeSessionLock;

void main(List<String> argv) {
  // A zone guard so ANY unhandled error — including async ones that bypass
  // _run's try/finally entirely (e.g. a failed log-file open in initLogging
  // surfaces on the event loop, not through main's await chain) — restores
  // the terminal before the process dies. Without this a mid-TUI crash leaves
  // the tty in raw mode: backspace/delete print junk and ^C is a literal byte.
  runZonedGuarded(
    () async {
      await _run(argv);
    },
    (Object error, StackTrace stack) {
      _activeSessionLock?.releaseSync();
      _activeSessionLock = null;
      emergencyTerminalRestore();
      stderr.writeln('tina crashed: $error\n$stack');
      exit(1);
    },
  );
}

Future<void> _run(List<String> argv) async {
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
      // mergedEnv (not the raw environment): a key configured in ~/.tina/config
      // rather than the shell must reach the live-models catalog too, or it
      // sees no credentials and silently skips that provider's /v1/models.
      _attachModelsDevCatalog(registry, mergedEnv);
      // Built-in per-provider rate limiting: every provider built from one
      // descriptor shares a launch-slot queue, so concurrent agents on the
      // same provider (folder-survey scouts, sub-agents, side panels) space
      // their requests instead of stampeding the endpoint's per-key limit.
      // Defaults: 1 request/second start spacing, at most 4 requests per
      // provider on the wire at once; `[limits] min_request_interval_ms` /
      // `max_concurrent_requests` in ~/.tina/config tune them (0 disables).
      registry.rateLimiter.minInterval = Duration(
          milliseconds: userConfig.limits?.minRequestIntervalMs ?? 1000);
      registry.rateLimiter.maxConcurrent =
          userConfig.limits?.maxConcurrentRequests ?? 4;
      // Per-provider request-rate ceilings from `[providers.<id>]
      // requests_per_minute`: each wins over the descriptor's built-in hint
      // (e.g. NIM's 40/min) and the global default above; 0 disables spacing
      // for that provider's queues. Installed before any provider builds (the
      // registry reads these when it lazily wraps each queue key), so order
      // here vs. registration only needs to precede the first `build`.
      for (final entry in userConfig.providers.entries) {
        final rpm = entry.value.requestsPerMinute;
        if (rpm != null) registry.setRequestRate(entry.key, rpm);
      }
      // Wire retries live at the TOP of the provider policy stack, so a
      // re-attempt re-acquires a rate-limit slot (never a stampede past the
      // queue). 3 = the historical transport-internal retry count.
      registry.maxSendRetries = 3;

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
      if (config.showVersion) {
        stdout.writeln('tina $tinaVersion');
        return;
      }
      if (config.initConfig) {
        writeConfigTemplate(env: environment.env);
        _seedDefaultWorkflowQuietly(environment.env);
        return;
      }
      if (config.listSessions) {
        await _listSessions();
        return;
      }
      if (config.models != null) {
        await _printModels(config.models, registry);
        return;
      }

      // First-run seeding of the default DOT workflow (idempotent; also runs
      // for interactive launches so `default.dot` exists before the agent may
      // launch it via its launch_workflow tool).
      _seedDefaultWorkflowQuietly(environment.env);

      // Construct the session store once and hand it to buildAppComposition (it
      // would build an identical one internally). On `--resume <id>`, chdir to
      // the session's recorded working directory BEFORE any project-context read
      // so trust, AGENTS.md, the repo summary, the tool sandbox, and the
      // environment agent all resolve against the folder the session actually
      // lives in — not wherever tina was launched from. `--continue` is
      // folder-scoped by design and needs no chdir. `resumeCwdFor` is pure and
      // never throws on a bad id; resolveSession surfaces a missing session.
      final sessionStore = JsonlSessionStore.defaultLocation();
      if (config.resumeSessionId != null) {
        await _restoreSessionCwd(sessionStore, config.resumeSessionId!);
      }

      // Project-trust gate: decide once, before any agent is built, whether this
      // cwd's AGENTS.md may enter system prompts. Withholds it for an untrusted
      // project (headless skips, TUI asks on the tty before the TUI takes over)
      // unless --trust / [trust] default override. Stored on the shared pipeline
      // so every agent (main, sub, /spawn) honors the same decision.
      defaultPipeline.loadProjectContext =
          await _resolveProjectTrust(config, mergedEnv);

      final app = await buildAppComposition(
        config: config,
        registry: registry,
        store: sessionStore,
      );

      // Acquire the per-session lock when resuming/continuing an on-disk
      // session, so a second process can't corrupt this session's history
      // (concurrent appends to one .jsonl / racing manifest rewrites). Fresh
      // sessions have nothing on disk yet — no other process can know their id
      // — so they need no lock. initialManifest is non-null exactly when a
      // real session was loaded (resume, or --continue that found a match).
      await _acquireSessionLock(app, config);

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
      if (outcome == RunOutcome.setupWrote) {
        // Relaunch: release the lock so the next iteration re-acquires cleanly
        // (the lockfile still carries our PID, which is alive).
        await _releaseSessionLock();
        continue;
      }
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
  } catch (e, st) {
    // Any other error propagating through the run path: restore the terminal
    // (the tty may be in raw mode mid-TUI) and quit nonzero with the trace.
    // Zone-level errors that bypass this chain entirely (e.g. a failed
    // log-file open) are caught by main's runZonedGuarded handler, which
    // restores the terminal the same way.
    emergencyTerminalRestore();
    stderr.writeln('tina crashed: $e\n$st');
    exit(1);
  } finally {
    // Reap any tool subprocess still alive (a leaked backgrounded child), then
    // release the session lock and close logging. Covers every normal exit path
    // (interactive /quit, headless completion, setup relaunch). exit(0) here
    // also guarantees prompt termination: without it, pending background work
    // (the models dev catalog fetch) would keep the isolate alive indefinitely.
    await _releaseSessionLock();
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
      // Drop the session lock synchronously before exit (the finally won't run
      // once we call exit). A leaked lock is reclaimable via PID liveness, but
      // releasing here avoids littering on a normal SIGTERM.
      _activeSessionLock?.releaseSync();
      _activeSessionLock = null;
      // The tty may be mid-TUI raw mode — restore it before the process dies.
      emergencyTerminalRestore();
      exit(1);
    });
  }
}

/// Acquire the per-session lock when [app] is resuming/continuing an on-disk
/// session. On conflict (another live process holds it) the user is told and
/// the process exits — unless `--force` overrode the lock. Sets
/// [_activeSessionLock] so every exit path can release it. No-op for fresh
/// sessions (no manifest on disk) and non-file-backed stores.
Future<void> _acquireSessionLock(AppComposition app, Config config) async {
  if (app.initialManifest == null) return; // fresh session — nothing to guard
  final store = app.store;
  if (store is! JsonlSessionStore) return; // tests / non-file backends
  final sid = app.initialSessionId;
  if (sid.isEmpty) return;
  final lock = SessionLock(store.directoryFor(sid));
  final conflict = await lock.acquire(force: config.forceLock);
  if (conflict != null) {
    stderr.writeln(conflict.toMessage());
    exit(1);
  }
  _activeSessionLock = lock;
}

/// Release the held session lock (if any) and clear the module-level handle.
/// Idempotent.
Future<void> _releaseSessionLock() async {
  final lock = _activeSessionLock;
  if (lock == null) return;
  _activeSessionLock = null;
  await lock.release();
}

/// `--resume <id>`: enter the session's recorded working directory so the
/// project context (trust, AGENTS.md, repo summary, tool sandbox, env agent)
/// rebuilds against the folder the session lives in rather than the launch
/// folder. Safe no-op when the recorded cwd is absent (legacy session), already
/// matches the launch folder, or points at a directory that no longer exists
/// (warned + left in the launch folder, matching `--continue`'s fallback).
Future<void> _restoreSessionCwd(SessionStore store, String sessionId) async {
  final cwd = await resumeCwdFor(store, sessionId);
  if (cwd == null || cwd.isEmpty) return; // legacy session — nothing to restore
  final dir = Directory(cwd);
  if (dir.path == Directory.current.path) return; // already home
  if (!await dir.exists()) {
    stderr.writeln('resume: recorded cwd "$cwd" no longer exists — '
        'restoring in the launch folder (${Directory.current.path}) instead.');
    return;
  }
  try {
    Directory.current = dir;
    stderr.writeln('resumed session in $cwd');
  } catch (e) {
    stderr.writeln('resume: could not enter "$cwd": $e');
  }
}

Future<RunOutcome> _runInteractive(AppComposition app,
    {bool setupMode = false}) async {
  final coordinator = await TuiCoordinator.create(app: app);
  final result = await coordinator.run(setupMode: setupMode);
  return result;
}

/// `~/.tina/workflows`.
Directory _workflowsDir(Map<String, String> env) =>
    Directory(p.join(tinaDirFromEnv(env).path, 'workflows'));

/// Seed `~/.tina/workflows/default.dot` on first run. Failures (e.g. a
/// read-only `~/.tina`) warn on stderr and never block startup.
void _seedDefaultWorkflowQuietly(Map<String, String> env) {
  try {
    if (seedDefaultWorkflow(_workflowsDir(env))) {
      stdout.writeln('seeded ~/.tina/workflows/default.dot — the default '
          'graph the agent launches via its launch_workflow tool. Edit with '
          '/workflow edit default; delete it (or set [default] workflow = '
          '"none") if you don\'t want a default workflow available.');
    }
  } catch (e) {
    stderr.writeln('warning: could not seed the default workflow: $e');
  }
}

Future<void> _runNonInteractive(AppComposition app) async {
  // HeadlessHost is a UI-agnostic HostInterface: agent prose and tool lifecycle
  // to stdout, notices to stderr, and permission `ask`s refused with a flag
  // hint. Wiring it as both `sink` and `asker` keeps bin/ free of any terminal
  // type — no Screen, ChatRegion, or Spinner reaches the non-interactive path.
  final host = HeadlessHost();

  // `--workflow <name>` headless: run a DOT pipeline to completion. Each `box`
  // node runs as a real agent turn via the scheduler (headless auto-approves at
  // any human gate). Input comes from `--prompt`. The run is audited under
  // ~/.tina/runs/<id>; a non-success outcome exits non-zero. Node agents'
  // write/edit asks auto-deny headless (there is no one to prompt) — run with
  // `--yolo` or `--allow write`/`--allow edit` to let a workflow change files.
  final workflow = app.config.workflow;
  if (workflow != null) {
    final tinaDataDir = tinaDirFromEnv(app.environment.env);
    final runner = PipelineRunner(
      scheduler: app.scheduler,
      pipeline: app.pipeline,
      workflowsDir: Directory(p.join(tinaDataDir.path, 'workflows')),
      runsRoot: Directory(p.join(tinaDataDir.path, 'runs')),
      defaultModelReference: '${app.config.provider}/${app.config.model}',
    );
    final rawInput = app.config.prompt?.trim();
    try {
      final result = await runner.run(
        workflowName: workflow,
        sink: host,
        input: (rawInput == null || rawInput.isEmpty) ? null : rawInput,
      );
      if (result.runDir.isNotEmpty) {
        stderr.writeln('run transcript: ${result.runDir}');
      }
      if (!result.outcome.status.isOk) exit(1);
    } finally {
      await host.dispose();
      await app.store.close();
      await closeLogging();
    }
    return;
  }

  // `/index` headless: run the staleness dance directly (no agent turn). The
  // summary fleet runs via SummaryIndex.refresh (its own ephemeral composition),
  // so the non-interactive agent isn't needed — the dance's notices stream to
  // the HeadlessHost (stdout/stderr). confirm is null (no interactive input),
  // so the up-to-date branch reports and stops, matching the deleted bin's
  // `--dry-run` behavior.
  final prompt = app.config.prompt?.trim() ?? '';
  if (prompt == '/index') {
    // Load the on-disk allocations (a TUI session's approved layout) so the
    // headless run measures the SAME partition. Without this, every allocated
    // dir falls outside the default partition and gets classified as deleted —
    // destroying the approved layout's summaries.
    final idx = SummaryIndex(
      config: app.config,
      registry: app.registry,
      environment: app.environment,
      projectRoot: Directory.current.path,
      allocations: AllocationsStore.forProject(Directory.current.path),
    );
    try {
      await runIndexDance(host: host, summaryIndex: idx, confirm: null);
    } finally {
      await host.dispose();
      await closeLogging();
    }
    return;
  }

  // Normal headless turns run the plain agent. Workflows are launched on demand
  // (use `--workflow <name>` for an explicit, run-to-completion pipeline);
  // there is no default-workflow routing of ordinary prompts.

  // The headless agent runs one turn with the base tools and the un-widened
  // policy — withSubAgents: false preserves the pre-composition behavior (a
  // non-interactive run does not gain delegate/channel tools). The provider is
  // built here because this turn owns it: built on demand, closed in the
  // finally below (no other path shares the instance).
  final provider = app.buildStartupProvider();
  final history = app.initialHistory;
  final recorder = SessionRecorder(
    app.store,
    app.initialSessionId,
    app.initialConversationId,
    providerId: app.config.provider,
    baseUrl: app.config.baseUrl,
    cwd: Directory.current.path,
  );

  // Write-through persistence (#25): the engine AWAITS these observers at the
  // moment each message is produced, so a mid-turn kill (SIGKILL, OOM, crash)
  // leaves the completed exchanges on disk instead of losing the whole turn to
  // a turn-end flush. The store's append is crash-safe per line (flush +
  // torn-tail repair), so no batching is needed here. A compact is observed
  // once with the final post-compact list and rewrites the session file
  // wholesale (no synthetic marker message exists to intercept). Observer
  // failures are logged and swallowed — persistence must never abort a run
  // (the engine likewise catches, logs, and continues).
  final agent = buildAgent(
    pipeline: app.pipeline,
    scheduler: app.scheduler,
    conversationId: app.initialConversationId,
    provider: provider,
    host: host,
    policy: app.policy,
    config: app.config,
    withSubAgents: false,
    // Headless (#22a): pass the post-edit compile gate so a failed edit
    // feeds its `dart analyze` errors back to the model mid-turn.
    resultVerifier: DartAnalyzeVerifier(),
    onHistoryAppend: (m) async {
      try {
        await recorder.append(m);
      } catch (e, st) {
        _log.severe('session write-through failed', e, st);
      }
    },
    onHistoryReplace: (messages) async {
      try {
        await recorder.replace(messages);
      } catch (e, st) {
        _log.severe('session compact-replace failed', e, st);
      }
    },
  );

  // Append concise summary instruction for headless --prompt runs.
  final rawPrompt = app.config.prompt!;
  var userInput = rawPrompt + (
    rawPrompt.trim().isNotEmpty ? '\n' : ''
  ) + HeadlessHost.kHeadlessSummaryInstruction;

  // Startup tree-health check (#22b): a killed run persists its edits but not
  // the model's awareness of them; compaction can drop old per-edit verdicts;
  // and the break may pre-date the session or come from outside entirely (a
  // kill, a manual edit). The CURRENT tree state at startup is authoritative
  // regardless of transcript history — so analyze it here and, when it does
  // not compile, prepend a <tree-health> notice so the model fixes it FIRST.
  // Bounded 30s; silent skip on timeout/spawn failure; no new flags.
  if (File('pubspec.yaml').existsSync()) {
    final notice = await DartAnalyzeVerifier().projectCheck();
    if (notice != null) {
      userInput = '<tree-health>\n$notice\n</tree-health>\n\n$userInput';
    }
  }

  var aborted = false;
  // Liveness watchdog (#26): a wedge below the provider stack (an internal
  // await that never resolves — Run D sat silent 25+ minutes past its last
  // wire request) emits no agent-sink event AND has no request in flight, so
  // neither the stream-idle nor the request timeout can fire. Every sink call
  // lands on the host's event bus; the watchdog resets on each one and, when
  // the idle clock expires, tears the turn down through the cancel signal
  // with a diagnostic — the headless analogue of the budget guard's clean
  // exit-2. 0 disables.
  final cancelWatchdog = Completer<void>();
  HeadlessWatchdog? watchdog;
  StreamSubscription<AgentEvent>? watchdogSub;
  Timer? watchdogGrace;
  if (app.config.watchdogSeconds > 0) {
    watchdog = HeadlessWatchdog(
      timeout: Duration(seconds: app.config.watchdogSeconds),
      onFire: (diagnostic) {
        stderr.writeln(diagnostic);
        // Give the cancel path a grace period to tear down cleanly (flushes,
        // session writes), then take the hard exit the budget guard would.
        cancelWatchdog.complete();
        watchdogGrace = Timer(const Duration(seconds: 5), () {
          stderr.writeln('[watchdog] graceful teardown missed the 5s grace — '
              'exiting hard');
          exit(2);
        });
      },
    )..start();
    watchdogSub = host.eventBus.events.listen(
        (e) => watchdog?.record(e.runtimeType.toString()),
        onDone: watchdog.dispose);
    cancelWatchdog.future.whenComplete(watchdog.dispose);
  }
  try {
    await agent.run(
      history: history,
      userInput: userInput,
      cancelSignal: cancelWatchdog.future,
    );
    aborted = agent.abortedReason != null || (watchdog?.fired ?? false);
  } finally {
    watchdogGrace?.cancel();
    await watchdogSub?.cancel();
    watchdog?.dispose();
    // Non-interactive hint goes to stderr so callers parsing stdout for the
    // agent's answer aren't disrupted. The RECORDER's id, not the
    // pre-allocation from startup: a store that couldn't honor our id mints
    // its own at first write, and the printed hint must point at the session
    // that actually exists on disk.
    if (app.initialSessionId.isNotEmpty) {
      stderr.writeln(
          'session: ${recorder.sessionId}  (resume: tina --resume ${recorder.sessionId})');
    }
    await host.dispose();
    await app.store.close();
    provider.close();
    await closeLogging();
  }
  if (aborted) exit(2);
}

/// Whether to run the first-run setup wizard over **stdin** — the non-tty
/// (piped/CI) path. A real terminal is handled by the in-TUI overlay instead
/// (see the `setupMode` branch in `main`). `--help` / `--init-config` /
/// `--list` / `--prompt` / `--models` short-circuit without setup;
/// `--setup` forces it; otherwise it runs only when stdin is NOT a terminal and
/// no config exists.
bool _shouldRunStdinSetup(List<String> argv, Environment environment) {
  if (stdioType(stdin) == StdioType.terminal) return false; // tty → overlay
  final nonInteractive = argv.any((a) =>
      a == '--prompt' ||
      a.startsWith('--prompt=') ||
      a == '--workflow' ||
      a.startsWith('--workflow=') ||
      a == '--help' ||
      a == '-h' ||
      a == '--version' ||
      a == '--list' ||
      a == '-l' ||
      a == '--init-config' ||
      a == '--models' ||
      a.startsWith('--models=') ||
      a == '--api-key' ||
      a.startsWith('--api-key='));
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

/// Attach the model catalogs to [registry] and kick off a non-blocking
/// load. Two layers:
///
/// 1. [ModelsDevCatalog] — the community models.dev registry, layered over
///    the compiled descriptor maps;
/// 2. [LiveModelsCatalog] — each provider's own `GET /v1/models` (the
///    actually-servable list, using the user's key), layered over (1).
///
/// `COCOON_MODELS_DEV=0` skips both fetches (handy for tests and hermetic
/// CI). Both loads are fire-and-forget; the compiled descriptor maps are the
/// source of truth until they complete, so the `/settings` picker and
/// bare-model resolution never block on the network.
/// Returns the catalog load futures (already running) so short-circuit
/// callers — `--models` — can await a complete catalog; the startup path
/// just ignores them (fire-and-forget, errors logged at FINE inside the
/// catalogs). Empty when disabled via `COCOON_MODELS_DEV=0`.
List<Future<void>> _attachModelsDevCatalog(
    ProviderRegistry registry, Map<String, String> env) {
  if (env['COCOON_MODELS_DEV'] == '0') return const [];
  final modelsDev = ModelsDevCatalog(env: env);
  final live = LiveModelsCatalog(env: env, inner: modelsDev);
  registry.catalog = live;
  return [
    modelsDev.load().catchError((Object _) {}),
    live.load(registry.descriptors).catchError((Object _) {}),
  ];
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

/// Print the resolved model list for one provider id (one `<id> — <name>` per
/// line), exit 0. Reuse the startup catalog attach, await its load, print
/// registry.modelsFor(id). No value passed → print known provider ids, exit 0.
/// Unknown provider → stderr naming the known providers, non-zero exit.
Future<void> _printModels(String? providerId, ProviderRegistry registry) async {
  // Await a complete catalog: models.dev + every listable provider's own
  // /v1/models, so the listing matches what the TUI picker would show.
  await Future.wait(_attachModelsDevCatalog(registry, Platform.environment));

  // Bare `--models ""` (an addOption can't distinguish no-value from
  // absent) lists the known provider ids instead.
  if (providerId == null || providerId.isEmpty) {
    for (final id in registry.providerIds) {
      stdout.writeln(id);
    }
    return;
  }

  final models = registry.modelsFor(providerId);
  if (models.isEmpty) {
    // Unknown provider → stderr with known providers, non-zero exit
    stderr.writeln('Unknown provider "$providerId". '
        'Known: ${registry.providerIds.join(', ')}');
    exit(1);
  }

  // Print models in "id — name" format
  for (final m in models) {
    stdout.writeln('${m.id} — ${m.name}');
  }
}
