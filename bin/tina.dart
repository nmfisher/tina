import 'package:tina_app/tina_app.dart';
import 'dart:async';
import 'dart:io';

import 'package:tina/config.dart';
import 'package:tina/config/setup.dart';
import 'package:tina/config/user_config.dart';
import 'package:tina/composition/config_providers.dart';
import 'package:tina/composition/git_input.dart';
import 'package:tina/composition/intent_input.dart';
import 'package:tina/composition/explore_project.dart';
import 'package:tina/composition/token_status.dart';
import 'package:tina/composition/plan_ui.dart';
import 'package:tina/composition/goal_ui.dart';
import 'package:tina/composition/index_status.dart';
import 'package:tina/composition/chat_renderer.dart';
import 'package:tina/composition/timestamp_chat.dart';
import 'package:tina/composition/models_dev_seed.dart';
import 'package:tina/composition/version_status.dart';
import 'package:tina/logging.dart';

import 'package:tina/host/headless_watchdog.dart';
import 'package:tina/session_commands/headless_commands.dart';
import 'package:tina/session_commands/startup_session_picker_backend.dart';

import 'package:tina_engine/tina_engine.dart';

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
      // Providers discovered from models.dev's api.json register BEFORE the
      // config pass: registerConfigProviders must see the seeded descriptor
      // so a wire-less `[providers.<id>]` block merges its `models` /
      // `max_output` curation into it instead of being discarded as a
      // custom provider with no base_url. Config-declared custom providers
      // (explicit wire + base_url) still replace the seeded descriptor
      // wholesale, and their key/base_url reach requests through the env
      // overlay either way. The seed still runs before the catalogs attach:
      // LiveModelsCatalog enumerates registry.descriptors at attach time.
      final providerCatalog = await _seedModelsDevProviders(
        registry,
        mergedEnv,
      );
      registerConfigProviders(registry, userConfig);
      // mergedEnv (not the raw environment): a key configured in ~/.tina/config
      // rather than the shell must reach the live-models catalog too, or it
      // sees no credentials and silently skips that provider's /v1/models.
      final catalogFutures = <Future<void>>[
        ..._attachModelsDevCatalog(registry, mergedEnv),
        // Fire-and-forget for STARTUP — the registry is already seeded from
        // the cache, so the TUI never waits on the network. But the result must
        // not be deferred to the next launch either: the moment the fresh
        // api.json lands, register whatever it adds into the LIVE registry, so
        // a provider discovered since the last cache write shows up in
        // /settings and the pickers without a restart. Registration is
        // idempotent (id-keyed, collision-checked), so a no-op run costs
        // nothing.
        if (providerCatalog != null)
          providerCatalog
              .refresh()
              .then((_) {
                registerModelsDevProviders(
                  registry: registry,
                  providers: providerCatalog.providers,
                );
              })
              .catchError((Object _) {}),
      ];
      // Built-in per-provider rate limiting: every provider built from one
      // descriptor shares a launch-slot queue, so concurrent agents on the
      // same provider (folder-survey scouts, sub-agents, side panels) space
      // their requests instead of stampeding the endpoint's per-key limit.
      // Defaults: 1 request/second start spacing, at most 4 requests per
      // provider on the wire at once; `[limits] min_request_interval_ms` /
      // `max_concurrent_requests` in ~/.tina/config tune them (0 disables).
      // Per-provider ceilings (`[providers.<id>] requests_per_minute` /
      // `min_request_interval_ms`) and the both-set warning live in
      // [applyRateLimitConfig] — shared with /settings, so a saved rate-limit
      // change applies NOW to this live registry instead of on the next
      // launch. Warnings go to stderr here; the settings panel collects them.
      for (final w in applyRateLimitConfig(registry, userConfig)) {
        stderr.writeln(w);
      }
      // Wire retries live at the TOP of the provider policy stack, so a
      // re-attempt re-acquires a rate-limit slot (never a stampede past the
      // queue). 3 = the historical transport-internal retry count.
      registry.maxSendRetries = 3;

      final Config config;
      try {
        config = Config.parse(
          argv,
          env: mergedEnv,
          registry: registry,
          userConfig: userConfig,
        );
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
        await _listSessions(config);
        return;
      }
      if (config.models != null) {
        await _printModels(config.models, registry, catalogFutures);
        return;
      }

      final launch = config.launch;

      // First-run seeding of the default DOT workflow (idempotent; also runs
      // for interactive launches so `default.dot` exists for the user's
      // /workflow commands).
      _seedDefaultWorkflowQuietly(environment.env);

      // The startup paths below need only a read-only view of saved
      // sessions. Resolve it via the SP2 index (a [SessionIndex]) rather
      // than the full store: the picker and cwd restore run before any
      // plugin runtime exists. A full store is built only when a session is
      // actually resumed — the launcher hands THAT instance to
      // buildAppComposition, so there is still exactly one store per process
      // and one construction path. SP3: selection follows [sessions]
      // provider/root from config — the same id the composition validates
      // when mounting the store plugin, so startup reads and the runtime
      // always see one backend.
      final index = resolveSessionIndex(
        provider: config.sessionStoreProvider,
        root: config.sessionStoreRoot == null
            ? null
            : Directory(config.sessionStoreRoot!),
      );
      var resume = launch.startup.resume;
      if (launch.startup.resumePicker) {
        try {
          if (!stdin.hasTerminal) {
            stderr.writeln(
              '--resume without an id needs an interactive terminal. '
              'Use --list, then --resume <id>.',
            );
            exitCode = 64;
            return;
          }
          final id = await pickStartupSessionId(await index.listSessions());
          if (id == null) return;
          resume = ResumeRequest(resumeSessionId: id);
        } finally {
          // Composition takes ownership only after a selection succeeds.
          if (resume.resumeSessionId == null) {
            registry.catalog?.close();
          }
        }
      }
      if (resume.resumeSessionId != null) {
        await _restoreSessionCwd(index, resume.resumeSessionId!);
      }

      // Project-trust gate: decide once, before any agent is built, whether this
      // cwd's AGENTS.md may enter system prompts. Withholds it for an untrusted
      // project (headless skips, TUI asks on the tty before the TUI takes over)
      // unless --trust / [trust] default override. Captured by the runtime pipeline
      // so every agent (main, sub, /spawn) honors the same decision.
      final loadWorkspaceContext = await _resolveProjectTrust(
        launch.startup,
        mergedEnv,
      );

      // PT0: the pause gate is born here — the earliest point that can see
      // both the composition and its plugins — so the explore_project plugin
      // and the runtime meter/pause on ONE gate instead of each building its
      // own.
      final pauseGate = PauseGate();
      final app = await buildAppComposition(
        config: launch.runtime,
        resumeRequest: resume,
        registry: registry,
        // No pre-built store: the jsonl plugin (mounted by the composition
        // when nothing else provides sessionStoreServiceKey) owns store
        // construction and its close. The launcher's pre-runtime reads used
        // the read-only SessionIndex instead (see resolveSessionIndex).
        loadWorkspaceContext: loadWorkspaceContext,
        pauseGate: pauseGate,
        plugins: [
          // The default transcript appearance is a scope contribution, so a
          // plugin whose id sorts before `tina.chat-renderer` overrides it
          // (activation registers contributions in plugin-id order; the first
          // registered renderer that handles a ChatBlock wins).
          chatRendererPlugin(),
          // Decorates the default look with a per-line time gutter. Id sorts
          // before `tina.chat-renderer`, so its renderer registers first and
          // delegates back to the built-in for the rows themselves.
          timestampChatPlugin(),
          // PT0 self-gating: the interactivity decision travels WITH the
          // plugin as a plain parameter, and a headless launch contributes
          // nothing (the launcher no longer decides for the plugin).
          configuredGitInputPlugin(
            environment.env,
            interactive: !launch.startup.nonInteractive,
          ),
          configuredIntentInputPlugin(
            environment.env,
            interactive: !launch.startup.nonInteractive,
          ),
          // explore_project crosses the scope like every other registry tool;
          // the tool fails closed when Typesafe isn't configured. The tool is
          // mounted unconditionally — /explore turns read it from the scope
          // whether or not a TUI conversation is ever built.
          configuredExploreProjectPlugin(
            env: environment.env,
            pauseGate: pauseGate,
          ),
          planUiPlugin(store: PlanStore()),
          goalUiPlugin(store: GoalStore()),
          indexProgressPlugin(),
          tokenStatusPlugin(),
          indexStatusPlugin(),
          versionStatusPlugin(),
          versionStatusUiPlugin(),
        ],
      );

      try {
        // Acquire the per-session lock when resuming/continuing an on-disk
        // session, so a second process can't corrupt this session's history
        // (concurrent appends to one .jsonl / racing manifest rewrites). Fresh
        // sessions have nothing on disk yet — no other process can know their id
        // — so they need no lock. initialManifest is non-null exactly when a
        // real session was loaded (resume, or --continue that found a match).
        await _acquireSessionLock(app, launch.startup);

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
          await _runNonInteractive(app, launch.startup);
          return;
        }

        // Setup mode = forced (--setup) or unconfigured on a tty (no resolvable
        // key for the default provider). The overlay collects config and writes
        // ~/.tina/config; on setupWrote we loop to re-parse + re-launch with it.
        final isTty = stdioType(stdin) == StdioType.terminal;
        final setupMode = config.setup || (config.apiKey.isEmpty && isTty);
        final outcome = await _runInteractive(
          app,
          terminal: launch.terminal,
          setupMode: setupMode,
        );
        if (outcome == RunOutcome.setupWrote) {
          // Relaunch: release the lock so the next iteration re-acquires cleanly
          // (the lockfile still carries our PID, which is alive).
          await _releaseSessionLock();
          continue;
        }
        if (outcome == RunOutcome.setupCancelled) {
          stderr.writeln(
            'Setup cancelled. Re-run with --setup or set ANTHROPIC_API_KEY.',
          );
        }
        return;
      } finally {
        await app.dispose();
        registry.catalog?.close();
      }
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
    exit(exitCode);
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
Future<void> _acquireSessionLock(
  AppComposition app,
  StartupOptions config,
) async {
  if (app.initialManifest == null) return; // fresh session — nothing to guard
  final store = app.store;
  // SP4: locking is a capability, not a backend type test. Stores that don't
  // implement LockableSessionStore skip locking exactly as before.
  if (store is! LockableSessionStore) return;
  final sid = app.initialSessionId;
  if (sid.isEmpty) return;
  final lock = SessionLock.forNamespace(store.lockNamespaceFor(sid));
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
Future<void> _restoreSessionCwd(SessionIndex index, String sessionId) async {
  final cwd = await index.cwdFor(sessionId);
  if (cwd == null || cwd.isEmpty) return; // legacy session — nothing to restore
  final dir = Directory(cwd);
  if (dir.path == Directory.current.path) return; // already home
  if (!await dir.exists()) {
    stderr.writeln(
      'resume: recorded cwd "$cwd" no longer exists — '
      'restoring in the launch folder (${Directory.current.path}) instead.',
    );
    return;
  }
  try {
    Directory.current = dir;
    stderr.writeln('resumed session in $cwd');
  } catch (e) {
    stderr.writeln('resume: could not enter "$cwd": $e');
  }
}

Future<RunOutcome> _runInteractive(
  AppComposition app, {
  bool setupMode = false,
  required TerminalConfig terminal,
}) async {
  final coordinator = await TuiCoordinator.create(app: app, terminal: terminal);
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
      stdout.writeln(
        'seeded ~/.tina/workflows/default.dot — the default '
        'graph for user-launched workflows (/workflow run). Edit with '
        '/workflow edit default; delete it (or set [default] workflow = '
        '"none") if you don\'t want a default workflow available.',
      );
    }
  } catch (e) {
    stderr.writeln('warning: could not seed the default workflow: $e');
  }
}

Future<void> _runNonInteractive(
  AppComposition app,
  StartupOptions startup,
) async {
  // HeadlessHost is a UI-agnostic HostInterface: agent prose and tool lifecycle
  // to stdout, notices to stderr, and permission `ask`s refused with a flag
  // hint. Wiring it as both `sink` and `asker` keeps bin/ free of any terminal
  // type — no Screen, ChatRegion, or Spinner reaches the non-interactive path.
  final resources = RuntimeResources();
  return resources.run(() async {
    // `permissionHints: false` under --yolo: a refusal must not suggest a
    // flag that is already in effect.
    // Permission asks surfaced headless (auto-denied). The `--goal` loop
    // reads this list: any new entry during a turn means the run needed an
    // approval no one can grant → exit 3. Other headless paths ignore it.
    final permissionAsks = <String>[];
    final host = HeadlessHost(
      permissionHints: !startup.yolo,
      onPermissionAsk: (ask) =>
          permissionAsks.add('${ask.toolName}:${ask.key}'),
    );
    resources.own(host.dispose);

    // `--goal <text>` headless: loop turns (no user present) until the goal
    // judge rules the goal achieved or a cap trips. Shares the setup below
    // (tracker hydration, provider, recorder, driver, watchdog) with the
    // --prompt path and diverges only at turn-running. Goal mode itself never
    // widens permissions — `--goal` and `--yolo` are different paradigms.
    // Without --yolo every ask is auto-denied and the first denial ends the
    // run (exit 3); with --yolo the policy is pre-widened by composition, so
    // asks never surface at all (identical to a --prompt run's posture). The
    // judge reads only a digest of the transcript, never raw tool output.
    // Exit codes: 0 achieved; 1 cap reached or judge repeatedly unavailable;
    // 2 aborted; 3 permission block.
    final goalText = startup.goal;
    final goalStore = goalText == null
        ? null
        : app.pluginScope?.lookup(goalStoreServiceKey);

    // `--workflow <name>` headless: run a DOT pipeline to completion. Each `box`
    // node runs as a real agent turn via the scheduler (headless auto-approves at
    // any human gate). Input comes from `--prompt`. The run is audited under
    // ~/.tina/runs/<id>; a non-success outcome exits non-zero. Node agents'
    // write/edit asks auto-deny headless (there is no one to prompt) — run with
    // `--yolo` or `--allow write`/`--allow edit` to let a workflow change files.
    final workflow = startup.workflow;
    if (workflow != null) {
      final tinaDataDir = tinaDirFromEnv(app.environment.env);
      final runner = PipelineRunner(
        scheduler: app.scheduler,
        pipeline: app.pipeline,
        workflowsDir: Directory(p.join(tinaDataDir.path, 'workflows')),
        runsRoot: Directory(p.join(tinaDataDir.path, 'runs')),
        defaultModelReference: '${app.config.provider}/${app.config.model}',
        yolo: app.config.yolo,
      );
      final rawInput = startup.prompt?.trim();
      try {
        final result = await runner.run(
          workflowName: workflow,
          sink: host,
          input: (rawInput == null || rawInput.isEmpty) ? null : rawInput,
        );
        if (result.runDir.isNotEmpty) {
          stderr.writeln('run transcript: ${result.runDir}');
        }
        if (!result.outcome.status.isOk) exitCode = 1;
      } finally {
        await closeLogging();
      }
      return;
    }

    // Goal/plan persistence for headless runs: hydrate the stores from the
    // startup manifest BEFORE command dispatch (so a headless `/goal` sees
    // restored state), then install the persist hooks once the recorder
    // exists (fixed sid/cid — a headless run has exactly one conversation).
    // Fresh session: initialManifest is null → nothing to hydrate.
    final headlessTrackers = (() {
      final goals = app.pluginScope?.lookup(goalStoreServiceKey);
      final plans = app.pluginScope?.lookup(planStoreServiceKey);
      if (goals == null || plans == null) return null;
      final binder = TrackerPersistence(
        goalStore: goals,
        planStore: plans,
        store: app.store,
      );
      binder.hydrate(
        app.initialManifest?.conversations
            .where((c) => c.id == app.initialConversationId)
            .firstOrNull,
        conversationId: app.initialConversationId,
      );
      return binder;
    })();

    final commandRuntime = headlessCommands(app);
    resources.own(commandRuntime.dispose);
    final commands = CommandRegistry(commandRuntime.scope);
    var rawPrompt = startup.prompt!;
    if (!startup.goalMode) {
      // `--goal` skips command dispatch: it is a user-input surface and goal
      // mode has no user — the seeded goal is delivered to the agent verbatim
      // via the goal middleware.
      final commandCancel = Completer<void>();
      final commandSignal = ProcessSignal.sigint.watch().listen((_) {
        if (!commandCancel.isCompleted) commandCancel.complete();
      });
      CmdResult commandResult;
      try {
        commandResult = await commands.dispatch(
          rawPrompt,
          host: host,
          conversationId: app.initialConversationId,
          cancelSignal: commandCancel.future,
        );
      } finally {
        await commandSignal.cancel();
      }
      if (commandResult is CmdHandled || commandResult is CmdExit) {
        if ((commandResult is CmdHandled && commandResult.failed) ||
            commandCancel.isCompleted) {
          exitCode = 1;
        }
        await closeLogging();
        return;
      }
      if (commandResult case CmdRun(:final prompt)) rawPrompt = prompt;
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
    resources.own(provider.close);
    resources.own(app.scheduler.dispose);
    final history = app.initialHistory;
    final recorder = SessionRecorder(
      app.store,
      app.initialSessionId,
      app.initialConversationId,
      providerId: app.config.provider,
      baseUrl: app.config.baseUrl,
      cwd: Directory.current.path,
      // Stamp the conversation meta at creation, mirroring the TUI's
      // initialRecorder: the model this run ACTUALLY used (the --model flag or
      // the config default) lands in the manifest, so a later headless
      // --resume/--continue resolves it via buildStartupProvider instead of
      // silently falling back to the config default. The system prompt stays
      // null (re-derived from the static main role on resume, like
      // session_manager's capture). On resume the recorder attaches to an
      // existing conversation, so this meta is write-once for fresh sessions
      // only — it never clobbers a persisted swap.
      meta: ConversationMetaInput.primary(
        providerId: app.config.provider,
        provider: provider,
        baseUrl: app.config.baseUrl,
        policy: app.policy,
      ),
    );

    // Install the tracker persist hooks now that the recorder exists (they
    // need it for ensureRegistered). persistIfPresent captures any /goal or
    // /plan mutation made during command dispatch above, which ran before the
    // hooks were in place; it skips when both trackers are empty so a run
    // that never touched them doesn't force-register a fresh session.
    headlessTrackers?.install(
      sessionIdFor: (_) => recorder.sessionId,
      ensureRegisteredFor: (_) => recorder.ensureRegistered(),
    );
    headlessTrackers?.persistIfPresent(app.initialConversationId);

    // `--goal`: seed the store only after the tracker hooks exist, so the
    // mutate→persist-hook chain registers the conversation in the manifest
    // (same posture as a TUI `/goal`; a store seeded before the hooks would
    // never reach disk).
    if (goalStore != null && goalText != null) {
      goalStore.set(app.initialConversationId, goalText);
    }

    // Write-through persistence (#25): the engine AWAITS these observers at the
    // moment each message is produced, so a mid-turn kill (SIGKILL, OOM, crash)
    // leaves the completed exchanges on disk instead of losing the whole turn to
    // a turn-end flush. The store's append is crash-safe per line (flush +
    // torn-tail repair), so no batching is needed here. A compact is observed
    // once with the final post-compact list and rewrites the session file
    // wholesale (no synthetic marker message exists to intercept). Observer
    // failures are logged and swallowed — persistence must never abort a run
    // (the engine likewise catches, logs, and continues).
    // The composed driver runs the turn — a scope-selected replacement
    // factory must own the headless loop exactly as it owns the TUI's.
    final driver = buildAgent(
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
      // #28: headless turns survive mid-stream transport blips — the agent
      // re-sends the failed step (15s→120s backoff) instead of aborting the
      // leg. Defaults to 5; --transport-retry-attempts 0 restores the
      // abort-on-first-error behavior.
      transportRetryAttempts: app.config.transportRetryAttempts,
    );

    // Append concise summary instruction for headless --prompt runs.
    var inputPrefix = '';
    var userInput =
        rawPrompt +
        (rawPrompt.trim().isNotEmpty ? '\n' : '') +
        HeadlessHost.kHeadlessSummaryInstruction;

    // Startup tree-health check (#22b): a killed run persists its edits but not
    // the model's awareness of them; compaction can drop old per-edit verdicts;
    // and the break may pre-date the session or come from outside entirely (a
    // kill, a manual edit). The CURRENT tree state at startup is authoritative
    // regardless of transcript history — so analyze it here and, when it does
    // not compile, prepend a <tree-health> notice. (#27) Whether the notice may
    // say "fix FIRST" depends on whether this run can actually edit: in a
    // read-only run that framing invites an edit-refusal spiral (Run A burned
    // 12 steps on refused edits), so wrapTreeHealth appends a do-not-try line
    // and the model answers with read-only tools instead.
    // Goal mode shares the verdict: its first turn gets the same prefix (the
    // --prompt path applies it via inputPrefix below).
    var treeHealthPrefix = '';
    if (File('pubspec.yaml').existsSync()) {
      final notice = await DartAnalyzeVerifier().projectCheck();
      if (notice != null) {
        treeHealthPrefix =
            '<tree-health>\n'
            '${DartAnalyzeVerifier.wrapTreeHealth(notice, editActionable: DartAnalyzeVerifier.editActionable(app.policy))}'
            '\n</tree-health>\n\n';
        inputPrefix = treeHealthPrefix;
        userInput = '$inputPrefix$userInput';
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
    //
    // #45: the transport retry ladder is agent-event-silent, so the watchdog
    // ALSO drinks from the wire feed ([Wire.onWireEvent] — attempt rungs, pool
    // rotation, backoff parks) — a run grinding through a bad provider patch
    // then reads as alive, not wedged. And the timeout itself is reconciled
    // against the ladder's worst case (watchdog≥ladder): the conservative
    // floor (no body bytes, no pool) already exceeds the 300s default, and a
    // real payload only lengthens the rungs the feed resets on.
    final cancelWatchdog = Completer<void>();
    HeadlessWatchdog? watchdog;
    StreamSubscription<AgentEvent>? watchdogSub;
    Timer? watchdogGrace;
    var watchdogSeconds = app.config.watchdogSeconds;
    if (watchdogSeconds > 0) {
      final reconciled = reconcileWatchdogWithLadder(
        watchdogSeconds: watchdogSeconds,
        bodyBytes: 0,
        members: 1,
      );
      if (reconciled.raised) {
        stderr.writeln(
          '[watchdog] ${watchdogSeconds}s is tighter than the retry '
          'ladder\'s worst case (${reconciled.seconds}s) — raising to it so a '
          'legitimately slow ladder is not aborted. 0 disables.',
        );
        watchdogSeconds = reconciled.seconds;
      }
      watchdog = HeadlessWatchdog(
        timeout: Duration(seconds: watchdogSeconds),
        onFire: (diagnostic) {
          // #45: name what the wire was last doing — the difference between
          // "wedged below the provider stack" and "parked on backoff" is the
          // first thing the postmortem needs.
          final wire = Wire.last;
          if (wire != null) {
            diagnostic +=
                ' Wire: $wire'
                '${wire.inFlight ? ' (in flight ${Wire.inFlightFor.inSeconds}s)' : ''}';
          }
          stderr.writeln(diagnostic);
          // Give the cancel path a grace period to tear down cleanly (flushes,
          // session writes), then take the hard exit the budget guard would.
          cancelWatchdog.complete();
          watchdogGrace = Timer(const Duration(seconds: 5), () {
            stderr.writeln(
              '[watchdog] graceful teardown missed the 5s grace — '
              'exiting hard',
            );
            exit(2);
          });
        },
      )..start();
      Wire.onWireEvent = (s) =>
          watchdog?.record('wire:${s.event}(${s.member})');
      watchdogSub = host.eventBus.events.listen(
        (e) => watchdog?.record(e.runtimeType.toString()),
        onDone: watchdog.dispose,
      );
      cancelWatchdog.future.whenComplete(() {
        Wire.onWireEvent = null;
        watchdog?.dispose();
      });
    }
    final cancelInput = Completer<void>();
    final inputSignal = ProcessSignal.sigint.watch().listen((_) {
      if (!cancelInput.isCompleted) cancelInput.complete();
    });
    final cancelTurn = Future.any<void>([
      cancelWatchdog.future,
      cancelInput.future,
    ]);
    try {
      if (goalStore != null && goalText != null) {
        // `--goal` mode: loop turns until the judge says achieved or a cap
        // trips. Shares the watchdog + cancel machinery above with --prompt.
        final outcome = await _runGoalTurns(
          app: app,
          driver: driver,
          history: history,
          goalStore: goalStore,
          goalText: goalText,
          maxTurns: startup.maxGoalTurns,
          cancelSignal: cancelTurn,
          permissionAsks: permissionAsks,
          treeHealthPrefix: treeHealthPrefix,
        );
        switch (outcome) {
          case GoalLoopOutcome.achieved:
            stderr.writeln('goal achieved');
          case GoalLoopOutcome.capReached:
            exitCode = 1;
            stderr.writeln(
              'goal not verified within $startup.maxGoalTurns '
              'turn(s) — exiting 1',
            );
          case GoalLoopOutcome.judgeUnavailable:
            exitCode = 1;
            stderr.writeln(
              'goal judge repeatedly failed to produce a verdict — '
              'exiting 1 (a goal that cannot be verified must not loop '
              'forever)',
            );
          case GoalLoopOutcome.permissionBlocked:
            exitCode = 3;
            final ask = permissionAsks.lastOrNull;
            stderr.writeln(
              'goal blocked on a permission ask${ask == null ? '' : ' ($ask)'} '
              '— no user is present to approve it. Goal mode never widens '
              'permissions: grant the rule via config, or run --yolo '
              'separately if you accept the risk. Exiting 3.',
            );
          case GoalLoopOutcome.aborted:
            aborted = true; // shares the --prompt exit-2 posture below
        }
      } else {
        final prepared = await app.inputRoutes?.prepare(
          text: rawPrompt,
          conversationId: app.initialConversationId,
          history: history,
          cancelSignal: cancelTurn,
        );
        final outcome = prepared == null
            ? InputOutcome.pass
            : await app.inputRoutes!.deliver(
                prepared,
                history: history,
                cancelSignal: cancelTurn,
                host: host,
                recorder: recorder,
              );
        if (prepared != null) {
          userInput =
              '$inputPrefix${prepared.text}\n'
              '${HeadlessHost.kHeadlessSummaryInstruction}';
          cancelTurn.then((_) => prepared.cancel());
        }
        if (outcome == InputOutcome.pass) {
          await driver.run(
            history: history,
            userInput: userInput,
            cancelSignal: cancelTurn,
          );
          aborted =
              driver.abortedReason != null ||
              (watchdog?.fired ?? false) ||
              cancelInput.isCompleted;
        } else {
          aborted =
              outcome != InputOutcome.handled ||
              (watchdog?.fired ?? false) ||
              cancelInput.isCompleted;
        }
      }
    } finally {
      await inputSignal.cancel();
      watchdogGrace?.cancel();
      await watchdogSub?.cancel();
      Wire.onWireEvent = null;
      watchdog?.dispose();
      // Non-interactive hint goes to stderr so callers parsing stdout for the
      // agent's answer aren't disrupted. The RECORDER's id, not the
      // pre-allocation from startup: a store that couldn't honor our id mints
      // its own at first write, and the printed hint must point at the session
      // that actually exists on disk.
      if (app.initialSessionId.isNotEmpty) {
        stderr.writeln(
          'session: ${recorder.sessionId}  (resume: tina --resume ${recorder.sessionId})',
        );
      }
      // Drain any in-flight goal/plan manifest write before the process ends.
      await headlessTrackers?.flush();
      await closeLogging();
    }
    if (aborted) exitCode = 2;
  });
}

/// The `--goal` turn loop adapter: turns + digest-based judging, per the pure
/// [GoalLoopRunner]. Each turn runs on the same [AgentDriver] a `--prompt`
/// run uses — the driver appends the user message itself. Judging reads a
/// digest of the transcript, never raw tool output.
///
/// Permission posture: the [HeadlessHost] auto-denies every ask headless and
/// reports it through [permissionAsks]; the first ask ends the run via the
/// runner's [GoalTurnAborted.permissionAsk] detection. Goal mode never
/// widens permissions, regardless of `--yolo`.
Future<GoalLoopOutcome> _runGoalTurns({
  required AppComposition app,
  required AgentDriver driver,
  required List<Message> history,
  required GoalStore goalStore,
  required String goalText,
  required int maxTurns,
  required Future<void>? cancelSignal,
  required List<String> permissionAsks,
  required String treeHealthPrefix,
}) async {
  var asksAtTurnStart = 0;
  var turn = 0;
  Future<RunAgentResult> runCheck({
    required String systemPrompt,
    required String task,
    required AgentSink sink,
  }) {
    // Zone.root: the judge is not part of any live invocation — strip any
    // ambient one so the standalone call does not mistake a finished turn
    // for its parent (same contract as the TUI's judge closure).
    return Zone.root.run(
      () => app.scheduler.runStandalone(
        systemPrompt: systemPrompt,
        task: task,
        sink: sink,
        parentReference: '${app.config.provider}/${app.config.model}',
        toolProfile: ToolProfile.readOnly,
        includeDelegate: false,
      ),
    );
  }

  final runner = GoalLoopRunner(
    goalText: goalText,
    maxTurns: maxTurns,
    runTurn: (userInput) async {
      asksAtTurnStart = permissionAsks.length;
      stderr.writeln('[goal] turn $turn/${maxTurns == 0 ? '∞' : maxTurns}');
      // Same two decorations the --prompt path applies: the headless summary
      // instruction on every turn, and the startup tree-health notice on the
      // first (a --goal run that must fix the tree deserves the same "the
      // tree is already broken" context a --prompt run gets). Later turns
      // carry the judge's continuation nudge instead of re-stating the goal.
      final decorated = turn == 1
          ? '$treeHealthPrefix$userInput\n${HeadlessHost.kHeadlessSummaryInstruction}'
          : '$userInput\n${HeadlessHost.kHeadlessSummaryInstruction}';
      await driver.run(
        history: history,
        userInput: decorated,
        cancelSignal: cancelSignal,
      );
      // Checked after the run: an ask raised late in the turn is just as
      // fatal as one raised early — the host denied it, and no one can
      // answer it.
      if (permissionAsks.length > asksAtTurnStart) {
        return GoalTurnAborted(permissionAsk: permissionAsks.last);
      }
      if (driver.abortedReason != null) {
        // A watchdog fire or SIGINT completes the cancel signal, the driver
        // aborts with a reason, and the loop stops here; the watcher in
        // [_runNonInteractive] still runs its grace/hard-exit posture.
        return const GoalTurnAborted();
      }
      return const GoalTurnComplete();
    },
    judge: ({required goalText, required digest}) async {
      final verdict = await judgeGoalCore(
        goalText: goalText,
        digest: digest,
        runCheck: runCheck,
      );
      if (verdict != null) {
        goalStore.recordVerdict(
          app.initialConversationId,
          verdict.verdict,
          verdict.evidence,
        );
      }
      return verdict;
    },
    buildDigest: () => GoalJudgeDigest.build(history),
    onTurn: (n) => turn = n,
  );
  return runner.run();
}
/// Whether to run the first-run setup wizard over **stdin** — the non-tty
/// (piped/CI) path. A real terminal is handled by the in-TUI overlay instead
/// (see the `setupMode` branch in `main`). `--help` / `--init-config` /
/// `--list` / `--prompt` / `--models` short-circuit without setup;
/// `--setup` forces it; otherwise it runs only when stdin is NOT a terminal and
/// no config exists.
bool _shouldRunStdinSetup(List<String> argv, Environment environment) {
  if (stdioType(stdin) == StdioType.terminal) return false; // tty → overlay
  final nonInteractive = argv.any(
    (a) =>
        a == '--prompt' ||
        a.startsWith('--prompt=') ||
        a == '--goal' ||
        a.startsWith('--goal=') ||
        a == '--workflow' ||
        a.startsWith('--workflow=') ||
        a == '--help' ||
        a == '-h' ||
        a == '--version' ||
        a == '--resume' ||
        a.startsWith('--resume=') ||
        a == '--list' ||
        a == '-l' ||
        a == '--init-config' ||
        a == '--models' ||
        a.startsWith('--models=') ||
        a == '--api-key' ||
        a.startsWith('--api-key='),
  );
  if (nonInteractive) return false;
  if (argv.any((a) => a == '--setup')) return true;
  return !userConfigFile(environment.env).existsSync();
}

/// Print every saved session to stdout in the same format `/sessions` uses
/// inside the TUI, then return. Lightweight: only the read-only session
/// index — no store, no provider, no TUI. Selection follows the parsed
/// config's [sessions] provider/root (SP3).
Future<void> _listSessions(RuntimeConfig config) async {
  final index = resolveSessionIndex(
    provider: config.sessionStoreProvider,
    root: config.sessionStoreRoot == null
        ? null
        : Directory(config.sessionStoreRoot!),
  );
  final sessions = await index.listSessions();
  if (sessions.isEmpty) {
    stdout.writeln('(no saved sessions)');
    return;
  }
  for (final s in sessions) {
    final stamp = _shortStamp(s.updatedAt);
    // The description (first substantive prompt) is what makes the entries
    // tell apart; stripped to one line like the pickers render it.
    final desc = (s.description ?? '').replaceAll(
      RegExp(r'[\x00-\x1f\x7f-\x9f]'),
      ' ',
    );
    stdout.writeln(
      '${s.id}  $stamp  ${s.messageCount}msg  ${s.title}'
      '${desc.isEmpty ? '' : ' — $desc'}',
    );
  }
}

String _shortStamp(DateTime t) {
  final l = t.toLocal();
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${pad(l.month)}-${pad(l.day)} '
      '${pad(l.hour)}:${pad(l.minute)}';
}

/// Register the providers models.dev knows about that tina can actually call,
/// and return the discovery catalog (null when disabled via
/// `COCOON_MODELS_DEV=0`).
///
/// Seeds from the on-disk cache ONLY — never the network — so startup stays off
/// the critical path: on a first run there is no cache, nothing is seeded yet,
/// and the caller's background [ModelsDevProviderCatalog.refresh] writes one and
/// registers what it found into the live registry (no restart). The cache is
/// read ignoring its age, so a cold start is deterministic rather than racing a
/// TTL boundary.
///
/// Seeded providers land in the registry — `/settings` and `--models` see them —
/// but stay out of `/model` and `/spawn` until curated in `/settings`; see
/// `registerModelsDevProviders` for the gating contract.
Future<ModelsDevProviderCatalog?> _seedModelsDevProviders(
  ProviderRegistry registry,
  Map<String, String> env,
) async {
  if (env['COCOON_MODELS_DEV'] == '0') return null;
  final catalog = ModelsDevProviderCatalog(env: env);
  await catalog.loadFromCache();
  registerModelsDevProviders(registry: registry, providers: catalog.providers);
  registry.providerCatalog = catalog;
  return catalog;
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
  ProviderRegistry registry,
  Map<String, String> env,
) {
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
Future<bool> _resolveProjectTrust(
  StartupOptions config,
  Map<String, String> env,
) async {
  final hasUi =
      !config.nonInteractive && stdioType(stdin) == StdioType.terminal;
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
    ..writeln(
      '  An AGENTS.md here can inject instructions into the agent. '
      'Trusting loads it.',
    )
    ..write('Load it? [y/N] ');
  final line = stdin.readLineSync()?.trim().toLowerCase() ?? '';
  return line == 'y' || line == 'yes';
}

/// Print the resolved model list for one provider id (one `<id> — <name>` per
/// line), exit 0. Await the startup catalog loads, print registry.modelsFor(id).
/// No value passed → print known provider ids, exit 0. Unknown provider →
/// stderr naming the known providers, non-zero exit.
Future<void> _printModels(
  String? providerId,
  ProviderRegistry registry,
  List<Future<void>> catalogFutures,
) async {
  // Await a complete catalog: the models.dev provider seed + model overlay +
  // every listable provider's own /v1/models, so the listing matches what the
  // TUI picker would show.
  await Future.wait(catalogFutures);

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
    stderr.writeln(
      'Unknown provider "$providerId". '
      'Known: ${registry.providerIds.join(', ')}',
    );
    exit(1);
  }

  // Print models in "id — name" format
  for (final m in models) {
    stdout.writeln('${m.id} — ${m.name}');
  }
}
