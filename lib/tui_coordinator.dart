import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:attractor/attractor.dart';

import 'package:tina/completion/git_file_provider.dart';
import 'package:tina/completion/command_completion_provider.dart';
import 'package:tina/composition/agent_composition.dart';
import 'package:tina/composition/app_composition.dart';
import 'package:tina/config.dart';
import 'package:tina/config/spawn_mru.dart';
import 'package:tina/config/user_config.dart';
import 'package:tina/environment/environment_index.dart';
import 'package:tina/environment/environment_record.dart';
import 'package:tina/environment/environment_runner.dart'
    show kDefaultEnvironmentModelRef;
import 'package:tina/host/tui_conversation_host.dart';
import 'package:tina/persistence/session_restore.dart';
import 'package:tina/pipeline/pipeline_runner.dart';
import 'package:tina/pipeline/workflow_permission_asker.dart';
import 'package:tina/pipeline/workflow_supervisor.dart';
import 'package:tina/regions/region_registry.dart';
import 'package:tina/self_update/release_checker.dart';
import 'package:tina/self_update/updater.dart';
import 'package:tina/tui/attention_queue.dart';
import 'package:tina/tui/panel_maximize.dart';
import 'package:tina/tui/run_panel_content.dart';
import 'package:tina/tui/tool_output_overlay.dart';
import 'package:tina/tui/workflow_editor_overlay.dart';
import 'package:tina/tui/workflow_viewer_overlay.dart';
import 'package:tina/platform/terminal_geometry.dart';
import 'package:tina/project/gitignore_guard.dart';
import 'package:tina/session_controller.dart';
import 'package:tina/summaries/summary_index.dart';
import 'package:tina/conversation.dart';
import 'package:tina/session_manager.dart';
import 'package:tina/tui/spawn_overlay.dart';
import 'package:tina/tui/tree_order.dart';
import 'package:tina/tui/panel_manager.dart';
import 'package:tina/tui/conversation_panel_coordinator.dart';
import 'package:tina/tui/resize_coordinator.dart';
import 'package:tina/tui/session_bar.dart';
import 'package:tina/tui/session_picker_overlay.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/backend/notcurses_backend.dart';
import 'package:tina/tui/setup_overlay.dart';
import 'package:tina/tui/prompts_overlay.dart';
import 'package:tina/tui/settings_panel.dart';
import 'package:tina/tui/spend_pause_dialog.dart';

/// Whether the top menu strip (File/Edit/View/Help) is laid out on screen.
///
/// Currently disabled — every menu item duplicates a slash command or key
/// binding (`/session new`, Ctrl+C, `/session switch`, `/help`), so the strip
/// no longer earns its row. The [MenuBar] is still constructed, wired to the
/// editor, and registered in the focus ring below; with this false all of that
/// is inert (render/canFocus/bounds/handleEvent each short-circuit on
/// `hasMenuBar`). Flip this to true to bring the strip back.
const _menuBarEnabled = false;

/// Outcome of [TuiCoordinator.run]: either the normal REPL ran and exited, or
/// the setup overlay wrote a config (main relaunches) or was cancelled.
enum RunOutcome { normal, setupWrote, setupCancelled }

/// Owns the interactive TUI construction and lifecycle.
///
/// The tree of spawned panels in the right column: each panel's parent link,
/// its base (connector-free) label, and the DFS order + per-depth indent used
/// by the layout. Kept as a standalone object (not [TuiCoordinator] instance
/// state) because the panel-adding closures live inside the static
/// [TuiCoordinator.create], which can't touch instance fields — those closures
/// capture a [SpawnTree] as a local instead.
class SpawnTree {
  /// The root conversation id (the primary). Panels never list it as a parent
  /// key; a panel whose parent is the root is a depth-1 direct spawn.
  final String rootId;

  /// spawnedPanelId → parent's conversationId (rootId for depth-1, else another
  /// spawned panel id for depth 2+).
  final Map<String, String> parentOf = {};

  /// conversationId → clean label (no chrome), so re-layout and `/model`
  /// switches can re-apply it without stacking prefixes.
  final Map<String, String> baseLabel = {};

  SpawnTree({required this.rootId});

  /// Tree depth of [id]: steps walking [parentOf] up to the root.
  int depthOf(String id) {
    var depth = 0;
    var current = id;
    final seen = <String>{};
    while (parentOf.containsKey(current) && !seen.contains(current)) {
      seen.add(current);
      current = parentOf[current]!;
      depth++;
    }
    return depth;
  }

  /// The panels in DFS pre-order (parent before its children), using
  /// [orderByTree] over [parentOf].
  List<PanelFrame> ordered(List<PanelFrame> panels) => orderByTree(
        items: panels,
        rootId: rootId,
        idOf: (p) => p.conversationId,
        parentOf: (p) => parentOf[p.conversationId],
      );

  /// Set a panel's base label and repaint its chrome. Centralizes label
  /// updates so they survive re-layout and `/model` switches.
  void relabelPanel(PanelFrame panel, String text) {
    baseLabel[panel.conversationId] = text;
    panel.relabel(text);
  }
}

/// Format a conversation panel's top-border title as `role (model)`, dropping
/// any `provider/` prefix from [model] so narrow right-column panels don't
/// truncate on it. Every conversation panel — primary, spawned, branched,
/// delegated sub-agent, restored — is titled through this so the border always
/// names both the role the conversation runs as and the model it runs under.
String panelLabel({required String role, required String model}) {
  final bare = model.contains('/') ? model.split('/').last : model;
  return '$role ($bare)';
}

/// The coordinator is created by [_runInteractive] and keeps all UI feature
/// wiring in one place so new features can be added without touching the
/// top-level entry point.
class TuiCoordinator {
  final Config config;
  final LlmProvider provider;
  final PermissionPolicy policy;
  final SessionStore store;
  final Screen screen;
  final LineEditor editor;
  final Spinner spinner;
  final SessionManager sessionManager;
  final MenuBar menuBar;
  final SessionController controller;
  final FocusManager focusManager;
  final Future<void> exitSignal;
  final SubAgentScheduler subAgentScheduler;
  final StreamSubscription<AgentEvent> progressSub;
  final StreamSubscription<String> pauseSub;
  final TerminalGeometry terminalGeometry;

  // Deferred first-paint state: rendered in [run()] after the alt screen is up,
  // so the paint actually reaches the screen (rendering before enterAltScreen
  // is silently lost — that left the menu bar blank on startup).
  final String? _warning;
  final void Function() _refreshSessionMenu;

  /// Owns the primary + spawned panels: their geometry (tiling layout), the focus
  /// ring, and shared-input relocation. Content-agnostic. Set in [create];
  /// [run]'s resize handler reaches it via this field so the panel structure
  /// survives resize.
  late final PanelManager panelManager;

  /// The single place that knows about both panels and conversations: the
  /// conversation→frame mapping, content relay, focus→active wiring, and the
  /// inverted host busy cue. Set in [create]; [run] reaches it via this field
  /// so content is relayed and the input repointed after resize.
  late final ConversationPanelCoordinator _contentCoordinator;

  /// Owns the canonical resize sequence (screen resize → session/menu/editor
  /// reconcile → retile frames → relay content → repoint input). Set in
  /// [create]; [run]'s SIGWINCH handler and the first-spawn blocks repoint at
  /// it via this field so the order lives in one place.
  late final ResizeCoordinator _resizeCoordinator;

  /// The tmux-style session list rendered into the info column when no side
  /// panels are open. Refreshed on every session change and on resize.
  final SessionBar _sessionBar;

  /// The spawned (side-panel) conversations currently tiled in the right
  /// column. Exposed so tests can drive a real focus change through the focus
  /// ring without running the REPL.
  List<PanelFrame> get spawnedPanels => panelManager.spawnedFrames;

  /// The tree of spawned panels (parent links + base labels + ordering). Kept as
  /// a standalone object rather than instance state because the panel-adding
  /// closures live inside the static [create], which can't touch instance
  /// fields; the closures capture [SpawnTree] as a local instead. Assigned in
  /// [create]; the getter reads it so tests can assert structure without the REPL.
  late final SpawnTree _tree;

  /// The spawned panels in tree (DFS pre-order) — parent before its children.
  /// Exposed for structural assertions without running the REPL.
  @visibleForTesting
  List<PanelFrame> get treeOrderedPanels =>
      _tree.ordered(panelManager.spawnedFrames);

  // The first-run setup overlay. Captured in create() (defaults to
  // runSetupOverlay); injectable for tests. Returns the written UserConfig on
  // confirm or null on cancel. Invoked from run() in setup mode.
  final Future<UserConfig?> Function() _setupOverlay;

  StreamSubscription<ProcessSignal>? _sigintSub;
  StreamSubscription<ProcessSignal>? _sigwinchSub;

  TuiCoordinator._({
    required this.config,
    required this.provider,
    required this.policy,
    required this.store,
    required this.screen,
    required this.editor,
    required this.spinner,
    required this.sessionManager,
    required this.menuBar,
    required this.controller,
    required this.focusManager,
    required this.exitSignal,
    required this.subAgentScheduler,
    required this.progressSub,
    required this.pauseSub,
    required this.terminalGeometry,
    required this.panelManager,
    required ConversationPanelCoordinator contentCoordinator,
    required String? warning,
    required void Function() refreshSessionMenu,
    required Future<UserConfig?> Function() setupOverlay,
    required SpawnTree tree,
    required ResizeCoordinator resizeCoordinator,
    required SessionBar sessionBar,
  })  : _warning = warning,
        _refreshSessionMenu = refreshSessionMenu,
        _setupOverlay = setupOverlay,
        _tree = tree,
        _contentCoordinator = contentCoordinator,
        _resizeCoordinator = resizeCoordinator,
        _sessionBar = sessionBar;

  static Future<TuiCoordinator> create({
    required AppComposition app,
    Stdio? io,
    TerminalGeometry? terminalGeometry,
    Future<UserConfig?> Function()? setupOverlay,
    // Injectable model+profile picker shared by `/spawn` and `/branch`. The real
    // pickers drive terminal overlays (runSpawnOverlay → runToolProfileOverlay) which
    // need a live terminal and so can't run under test. When omitted, the
    // closures capture the in-scope [pickSpawnedTarget] helper; tests pass a
    // canned (ref, profile) to drive the live fork body without the overlays.
    Future<({String ref, ToolProfile profile})?> Function()? spawnTargetPicker,
  }) async {
    final config = app.config;
    final reg = app.registry;
    // The initial conversation's provider, built on demand and owned by that
    // Conversation (closed with it on teardown / model swap). Later
    // conversations build their own via providerFactory below; the restore
    // fallback builds fresh ones through the same tear-off.
    final provider = app.buildStartupProvider();
    final policy = app.policy;
    final store = app.store;
    final stdio = io ?? const LiveStdio();
    final geometry = terminalGeometry ?? const StdoutTerminalGeometry();
    // Start full-width — no right column until a spawned agent creates one.
    final layout = ScreenLayout.fromSize(
      geometry.columns,
      geometry.lines,
      hasMenuBar: _menuBarEnabled,
      split: false,
    );
    final (:screen, :warning) = _createScreen(config, stdio, layout);

    // Use the notcurses native input backend when rendering through notcurses.
    // It polls notcurses's own input fd (opened off /dev/tty), so it bypasses
    // the shared-stdin relay entirely — keystrokes come straight from
    // notcurses's input queue. For ANSI screens, fall back to AnsiInputBackend.
    final InputBackend? inputBackend = screen.backend is NotcursesBackend
        ? (screen.backend as NotcursesBackend).createInputBackend()
        : null;

    final editor = LineEditor(
      screen: screen,
      input: inputBackend,
      macosOptionAsMeta: app.environment.isMacOS,
      debugKeys: app.environment.env['COCOON_DEBUG_KEYS'] == '1',
    )..completionProvider = GitFileCompletionProvider()
     ..commandProvider = const CommandCompletionProvider();

    // The initial (active) session's spinner, bound to the shared status row.
    final spinner = Spinner(enabled: stdio.hasTerminal, region: screen.status);

    // Exit signal shared between menu callbacks and the REPL loop.
    final exitCompleter = Completer<void>();
    final pipeline = app.pipeline;
    final scheduler = app.scheduler;

    // The TUI's single attention queue: human gates, loop-budget confirms,
    // and workflow permission asks serialize through it, so concurrent
    // background runs take the keyboard one at a time instead of racing on
    // `editor.readKey()`.
    final attentionQueue = AttentionQueue();

    // Constructs a provider for a new session/conversation, carrying over
    // CLI-level settings. The startup API key and base URL apply only to the
    // startup provider; a different provider is resolved afresh from the
    // environment and its descriptor (so `/session new glm:...` picks up
    // GLM_API_KEY rather than reusing the startup key).
    LlmProvider providerFactory(
        String providerId, String apiKey, String model, String? baseUrl) {
      final sameProvider = providerId == config.provider;
      return reg.build(
        '$providerId/$model',
        apiKeyOverride: sameProvider && apiKey.isNotEmpty ? apiKey : null,
        baseUrlOverride: sameProvider ? baseUrl : null,
        maxTokens: config.maxTokens,
        streamIdleTimeout: config.streamIdleTimeout,
        requestTimeout: config.requestTimeout,
      );
    }

    late final SessionManager sessionManager;
    // Forward-declared so the menu/session-menu closures below can reference
    // them; they're assigned before the closures ever run.
    late final MenuBar menuBar;
    late final SessionController controller;

    // Session bar lives in the info column; hidden when side panels are open.
    // The side-panel check is a late closure (assigned once [panelManager]
    // exists below) so [refreshSessionMenu] — declared before panelManager —
    // can call it without a forward reference.
    final sessionBar = SessionBar(screen);
    late bool Function() hasSidePanels;

    // Background-activity handler. Declared up here (nullable) so [hostFactory]
    // and the initial host can capture it; assigned once [refreshSessionMenu]
    // exists below. Invoked only long after [create] returns (when a background
    // conversation emits output), so it is always assigned by then.
    void Function(String)? handleBackgroundActivity;

    // Workflow-completion handler: the supervisor's onComplete hook routes a
    // finished run here. Same late-field pattern as [handleBackgroundActivity]
    // — the supervisor is constructed before the controller, so the hook is
    // assigned once the controller exists (below) and read at fire time.
    void Function(WorkflowRun)? handleWorkflowComplete;

    // Workflow-launch handler: the supervisor's onLaunch hook opens the run's
    // live panel (assigned below, once the panel machinery exists; invoked only
    // long after create returns, when an agent launches a workflow).
    void Function(WorkflowRun)? handleWorkflowLaunch;

    // Constructs the per-conversation terminal host. A background conversation
    // gets a fresh, detached chat region (so its output buffers until it is
    // switched to) and a no-op spinner; [TuiConversationHost.setActive] routes
    // it onto the screen and binds its spinner to the status row on switch.
    // The shared [editor] lets an active conversation read a permission
    // keystroke. isActive is true only for the initial conversation.
    HostInterface hostFactory({
      required String conversationId,
      required bool isActive,
    }) {
      final host = TuiConversationHost(
        conversationId: conversationId,
        chat: ScrollingTextRegion(screen)..detach(),
        spinner: Spinner(enabled: false),
        screen: screen,
        editor: editor,
        active: isActive,
      );
      host.onBackgroundActivity =
          () => handleBackgroundActivity?.call(conversationId);
      return host;
    }

    // Tools, the sub-agent catalog, the scheduler, and the per-conversation
    // Agent builder live in agent_composition.dart — app-level composition
    // shared with the headless path. The initial Agent and every later
    // session's Agent are built by buildAgent(); the SessionManager reuses it
    // as its agentBuilder.

    // The workflow supervisor: the main agent launches DOT workflows in the
    // background via its `launch_workflow` tool (lib/pipeline/launch_workflow_
    // tool.dart) and stops them with `stop_workflow`. One fresh runner per
    // launch; the run's node text + progress stream into a live run panel (the
    // host installs the panel sink on the run inside `onLaunch`), the chat
    // keeps the launch + completion notices, and on completion `onComplete`
    // fires the completion-turn hook (assigned to the controller below) so the
    // agent wakes with the outcome. Defined here so both the initial Agent and
    // the SessionManager's agentBuilder can wire it in.
    final tinaDataDir = tinaDirFromEnv(app.environment.env);
    final workflowsDir = Directory(p.join(tinaDataDir.path, 'workflows'));
    final runsRoot = Directory(p.join(tinaDataDir.path, 'runs'));
    PipelineRunner buildRunner() => PipelineRunner(
          scheduler: scheduler,
          pipeline: pipeline,
          workflowsDir: workflowsDir,
          runsRoot: runsRoot,
          defaultModelReference: '${app.config.provider}/${app.config.model}',
          screen: screen,
          editor: editor,
          // Workflow node agents prompt per write like the main agent; the
          // prompt renders into the run's own panel (see
          // WorkflowPermissionAsker — a run panel's host is inactive, so its
          // own asker can't be used).
          permissionAskerBuilder: (runSink) =>
              WorkflowPermissionAsker(sink: runSink, screen: screen,
                  editor: editor, attentionQueue: attentionQueue)
                  .ask,
          attentionQueue: attentionQueue,
        );
    final supervisor = WorkflowSupervisor(
      run: ({
        required workflowName,
        required sink,
        input,
        history,
        cancelSignal,
        onEvent,
      }) =>
          buildRunner().run(
            workflowName: workflowName,
            sink: sink,
            input: input,
            history: history,
            cancelSignal: cancelSignal,
            onEvent: onEvent,
          ),
      onComplete: (run) => handleWorkflowComplete?.call(run),
      onLaunch: (run) => handleWorkflowLaunch?.call(run),
    );

    // Region agents + the summary index: built once per session from the live
    // composition. The registry primes regions from the sidecar at session
    // start (pure file/git reads — zero LLM calls); the index runs the fleet
    // (allocate_region's background refresh + `/index`). Both are wired into
    // the main agent's tool set below and at the agentBuilder.
    final regions = RegionRegistry(
      projectRoot: Directory.current.path,
      defaultModel: config.regionsModel,
    );
    final summaryIndex = SummaryIndex(
      config: app.config,
      registry: app.registry,
      environment: app.environment,
      projectRoot: Directory.current.path,
      allocations: regions.allocations,
      spendLedger: app.spendLedger,
    );

    // `ask_user`: the agent poses multiple-choice questions; the user
    // navigates ↑/↓ within a question and ←/→ between questions, Enter
    // confirms. An empty answer list = the user cancelled (Esc).
    Future<List<Answer>> Function(List<Question>) askUser = (questions) async {
      final labels = await runQuestionOverlay(
        screen: screen,
        editor: editor,
        questions: [
          for (final q in questions)
            (
              text: q.text,
              options: [
                for (final o in q.options ?? const <Option>[]) o.label,
              ],
            ),
        ],
      );
      if (labels == null) return const [];
      return [
        for (var i = 0; i < questions.length; i++)
          Answer(
            value: labels[i],
            selectedOption: questions[i].options!.firstWhere(
              (o) => o.label == labels[i],
              orElse: () => Option(key: '${i + 1}', label: labels[i]),
            ),
          ),
      ];
    };

    // Build the initial session. Its host adopts screen.chat as its (active)
    // region and the shared spinner (bound to the status row), so it is on
    // screen from construction — active: true gives it an interactive asker.
    final initialSessionId = app.initialSessionId;
    final initialConversationId = app.initialConversationId;
    final initialHistory = app.initialHistory;
    // Resolve the main role's system prompt ONCE so the recorder's captured
    // metadata and the agent's actual prompt can't drift (and aren't compiled
    // twice). Stored in the conversation meta so resume replays the exact prompt.
    final initialSystem = resolveMainPrompt(pipeline,
        overrides: config.promptOverrides,
        safeMode: config.safeMode,
        loadProjectContext: pipeline.loadProjectContext);
    final initialRecorder = SessionRecorder(
        store, initialSessionId, initialConversationId,
        providerId: config.provider,
        baseUrl: config.baseUrl,
        cwd: Directory.current.path,
        meta: ConversationMetaInput.primary(
          providerId: config.provider,
          provider: provider,
          baseUrl: config.baseUrl,
          policy: policy,
          systemPrompt: initialSystem,
        ));
    final initialHost = TuiConversationHost(
      conversationId: initialConversationId,
      chat: screen.chat,
      spinner: spinner,
      screen: screen,
      editor: editor,
      active: true,
    );
    initialHost.onBackgroundActivity =
        () => handleBackgroundActivity?.call(initialConversationId);
    final initialAgent = buildAgent(
      pipeline: pipeline,
      scheduler: scheduler,
      conversationId: initialConversationId,
      provider: provider,
      host: initialHost,
      policy: policy,
      config: config,
      supervisor: supervisor,
      regions: regions,
      summaryIndex: summaryIndex,
      askUser: askUser,
      system: initialSystem,
    );
    final initialConversation = Conversation(
      id: initialConversationId,
      label: provider.model,
      agent: initialAgent,
      provider: provider,
      host: initialHost,
      policy: policy,
      recorder: initialRecorder,
      initialHistory: initialHistory,
    );

    sessionManager = SessionManager(
      initialConversation: initialConversation,
      initialProviderId: config.provider,
      initialApiKey: config.apiKey,
      initialBaseUrl: config.baseUrl,
      initialSessionId: initialSessionId,
      cwd: Directory.current.path,
      providerFactory: providerFactory,
      hostFactory: hostFactory,
      agentBuilder: ({
        required String conversationId,
        required LlmProvider provider,
        required HostInterface host,
        required PermissionPolicy policy,
      }) =>
          buildAgent(
        pipeline: pipeline,
        scheduler: scheduler,
        conversationId: conversationId,
        provider: provider,
        host: host,
        policy: policy,
        config: config,
        supervisor: supervisor,
        regions: regions,
        summaryIndex: summaryIndex,
        askUser: askUser,
      ),
      sessionStore: store,
    );

    // On resume, rehydrate every conversation the session contained — not just
    // the active one — so sub-agent transcripts, /spawn panels, and /clear'd
    // conversations all come back, each under the model/provider/tools/policy it
    // ran with. The active conversation is the one already built above; the rest
    // are restored here as background conversations and added to the session.
    final manifest = app.initialManifest;
    // Non-primary conversations (spawns + sub-agents) collected during restore
    // and wrapped in a right-column panel once the panel infra (spawnedPanels,
    // focusManager, layout closure) is set up below. Empty on a fresh start.
    final restoredPanels = <Conversation>[];
    // Each restored panel's parent conversation id (from its meta), so the
    // layout can nest it under its spawner. Mirrors the live /spawn edge.
    final restoredParentOf = <String, String?>{};
    // Each restored panel's display title, recomputed from its meta as
    // `role (model)` so every panel — including delegated sub-agents, whose
    // persisted label is role-only — shows both. Mirrors the live panel titles.
    final restoredLabelOf = <String, String>{};
    if (manifest != null) {
      final restoreCtx = RestoreContext(
        registry: reg,
        pipeline: pipeline,
        config: config,
        store: store,
        scheduler: scheduler,
        hostFactory: hostFactory,
        sessionId: initialSessionId,
        activeConversationId: initialConversationId,
        // The account-provider FACTORY (not the initial conversation's
        // instance): each fallback conversation builds and owns its own, so
        // closeAll never double-closes a shared instance.
        accountProvider: app.buildStartupProvider,
      );
      for (final meta in manifest.conversations) {
        if (meta.id == initialConversationId) continue; // active, already built
        try {
          final conv = await restoreConversation(meta, restoreCtx);
          sessionManager.active.addConversation(conv);
          if (meta.kind != ConversationKind.primary) {
            restoredPanels.add(conv);
            restoredParentOf[conv.id] = meta.parentConversationId;
            restoredLabelOf[conv.id] = panelLabel(
              role: meta.targetName ?? 'main',
              model: meta.model ?? conv.provider.model,
            );
          } else {
            // A non-active primary (shouldn't happen, but be safe): just replay.
            if (conv.history.isNotEmpty) replayHistory(conv.host, conv.history);
          }
        } catch (_) {
          // A single unrecoverable conversation (unknown model/role, corrupt
          // meta) must not fail the whole restore — skip it and continue.
        }
      }
      // Make sure the manifest's active conversation is the in-memory active
      // pointer (it already is after construction, but a /clear shifts the
      // active id, so re-assert it).
      sessionManager.active.setActiveConversation(initialConversationId);
    }

    // View menu lists sessions; its items are rebuilt on every change.
    final viewMenu = Menu(label: 'View', shortcut: 0x76, items: <MenuItem>[]);

    void refreshSessionMenu() {
      final items = <MenuItem>[
        MenuEntry(
            label: 'New Session',
            onActivate: () => unawaited(controller.newSession())),
        const MenuSeparator(),
      ];
      for (final s in sessionManager.listSessions()) {
        final marker = s.isActive ? '● ' : '  ';
        final running = s.isRunning ? ' (running)' : '';
        items.add(MenuEntry(
          label: '$marker${s.label}$running',
          onActivate: () => controller.switchSession(s.id),
        ));
      }
      viewMenu.items
        ..clear()
        ..addAll(items);
      menuBar.render();
      // Refresh the session bar too (same data, persistent form). Hidden when
      // side panels own the info column or there's just one session.
      sessionBar.refresh(
        sessions: sessionManager
            .listSessions()
            .map((s) => (id: s.id, label: s.label, isActive: s.isActive,
                  isRunning: s.isRunning, unread: s.unread))
            .toList(),
        hasSidePanels: hasSidePanels(),
      );
    }

    /// A background conversation produced output: bump its session's unread
    /// badge and refresh the session chrome (menu, and the session bar once it
    /// is wired). [SessionManager.markBackgroundActivity] returns the session id
    /// only on the 0→1 transition, so this (and the optional bell) fires once
    /// per background burst rather than per streamed chunk. Local to [create]
    /// so it can close over [sessionManager] and [refreshSessionMenu].
    handleBackgroundActivity = (String conversationId) {
      final changed = sessionManager.markBackgroundActivity(conversationId);
      if (changed == null) return;
      refreshSessionMenu();
      if (const bool.fromEnvironment('TINA_BELL') ||
          Platform.environment['TINA_BELL'] == '1') {
        stdout.write('\x07'); // BEL
      }
    };

    menuBar = MenuBar(screen, [
      Menu(label: 'File', shortcut: 0x66, items: [
        MenuEntry(
            label: 'New Session',
            onActivate: () => unawaited(controller.newSession())),
        MenuSeparator(),
        MenuEntry(
            label: 'Exit',
            shortcutHint: 'Ctrl+C ×2',
            onActivate: () {
              if (!exitCompleter.isCompleted) exitCompleter.complete();
            }),
      ]),
      Menu(label: 'Edit', shortcut: 0x65, items: [
        MenuEntry(
            label: 'Clear Input',
            shortcutHint: 'Ctrl+C',
            onActivate: () {
              editor.inject(
                  ControlKey(ControlCode.ctrlC)); // triggers buffer clear
            }),
      ]),
      viewMenu,
      Menu(label: 'Help', shortcut: 0x68, items: [
        MenuEntry(
            label: 'Commands',
            onActivate: () {
              screen.chat.dim('(menu: help — use /help)\n');
            }),
      ]),
    ]);
    editor.menuBar = menuBar;

    // Session hotkeys: Alt+1..9 switches to session N, Alt+N creates a new
    // session, Alt+S opens the session picker. (n = 0x6e, s = 0x73; '1'..'9' are
    // 0x31..0x39.) Return true to consume so the editor ignores the key.
    editor.onAltKey = (AltKey key) {
      final sessions = sessionManager.listSessions();
      final digit = key.letter - 0x30; // '1' => 1 .. '9' => 9
      if (digit >= 1 && digit <= 9) {
        if (digit <= sessions.length) {
          controller.switchSession(sessions[digit - 1].id);
        }
        return true;
      }
      switch (key.letter) {
        case 0x6e /* n */ :
          unawaited(controller.newSession());
          return true;
        case 0x73 /* s */ :
          unawaited(controller.openSessionPicker?.call());
          return true;
      }
      return false;
    };

    // Moves the shared input line onto whichever panel owns the active
    // conversation. Forward-declared as a no-op here because the real body
    // needs [panelManager] (built just below); Dart closures capture this local
    // by reference, so callers always invoke the reassigned one. [run]'s resize
    // handler calls it with `force: true` so the input follows the resized panel.
    // After [contentCoordinator] is built, this is reassigned to its
    // [ConversationPanelCoordinator.relocateInput], which resolves the active
    // frame the same way the relocated create-local closure once did.
    void Function({bool force}) relocateInput = ({bool force = false}) {};

    // The conversation→frame + content coordinator. Forward-declared (late) here
    // because [renderImageToPanel] (defined below) reads it; it is assigned once
    // [panelManager] is built further down. Captured by reference like the other
    // create-locals, so callers always see the built instance.
    late final ConversationPanelCoordinator contentCoordinator;

    // The primary conversation's panel wraps screen.chat and — like every
    // spawned panel — draws its own chrome (a titled border using the
    // provider/model as the label). Its outer rect is assigned by
    // [PanelManager.layout] on first paint and resize.
    final primaryPanel = PanelFrame(
      screen: screen,
      label: panelLabel(role: 'main', model: provider.model),
      conversationId: initialConversationId,
    );

    // Focus ring: primary panel + menu are permanent members. Spawned panels
    // (right column) register dynamically via /spawn.
    final focusManager = FocusManager()
      ..register(primaryPanel)
      ..register(menuBar);
    editor.focusManager = focusManager;

    controller = SessionController(
      sessionManager: sessionManager,
      readLine: editor.readLine,
      sessionStore: store,
      exitSignal: exitCompleter.future,
      onSessionsChanged: refreshSessionMenu,
      onActiveFocusChanged: () => relocateInput(),
      autoCompactThreshold: config.autoCompactThreshold,
      environment: app.environment,
    );
    // Workflow completion → agent turn: the supervisor's onComplete hook wakes
    // the launching conversation with a synthetic turn carrying the outcome
    // (auto agent turn on completion), so the agent reports and acts on it.
    handleWorkflowComplete = controller.injectWorkflowResult;
    // Per-session draft input: a half-typed prompt survives switching to
    // another session and back. A command being typed isn't a draft — only
    // real prompt text is preserved.
    controller.saveInput = () {
      if (!editor.isEditing) return null;
      final state = editor.editState;
      if (state.buffer.trimLeft().startsWith('/')) {
        return (buffer: '', cursor: 0);
      }
      return state;
    };
    controller.restoreInput = (buffer, cursor) {
      editor.loadEditState(buffer, cursor);
    };
    // Session picker (Alt+S): switch among live sessions or resume a saved one.
    controller.openSessionPicker = () async {
      final live = sessionManager.listSessions()
          .map((s) => (
                id: s.id,
                label: s.label,
                isActive: s.isActive,
                isRunning: s.isRunning,
                unread: s.unread,
              ))
          .toList();
      List<({String id, String title, int messageCount})> disk;
      try {
        final metas = await store.listSessions();
        disk = metas
            .map((m) =>
                (id: m.id, title: m.title, messageCount: m.messageCount))
            .toList();
      } catch (_) {
        disk = const [];
      }
      final entry = await runSessionPickerOverlay(
        screen: screen,
        editor: editor,
        live: live,
        disk: disk,
      );
      if (entry == null) return;
      if (entry.live) {
        controller.switchSession(entry.id);
      } else {
        await controller.resumeIntoActive(entry.id);
        refreshSessionMenu();
      }
    };
    // DOT-pipeline workflows. The .dot files live in ~/.tina/workflows; each
    // run is audited under ~/.tina/runs/<id>. The main agent launches them in
    // the background via its `launch_workflow` tool (the supervisor wired
    // above) — never wrapping a chat turn; completion injects a turn with the
    // outcome. `/workflow list|show|new|edit` remain for browsing/editing.
    controller.workflowsDir = workflowsDir;
    // Names the default workflow file for /workflow list (no per-turn routing).
    controller.defaultWorkflow = app.config.defaultWorkflow;
    // `/workflow show` — visual graph viewer.
    controller.openWorkflowViewer = (name) async {
      try {
        final source = await PipelineRunner.readWorkflow(workflowsDir, name);
        final graph = parseDot(source);
        await runWorkflowViewer(
            screen: screen, editor: editor, graph: graph, title: name);
      } catch (e) {
        controller.active.host
            .showMessage('$e\n', style: HostMessageStyle.error);
      }
    };
    // `/output [n]` — full output of a capped tool call (the chat shows only
    // the first ~600 streamed chars). The ring lives on the active
    // conversation's host; newest first.
    controller.openToolOutput = (index) async {
      final host = sessionManager.activeConversation.host;
      if (host is! TuiConversationHost) {
        host.showMessage('no capped tool output in this conversation\n',
            style: HostMessageStyle.warning);
        return;
      }
      if (index >= host.cappedOutputs.length) {
        host.showMessage(
            'no capped tool output at /output ${index + 1} '
            '(${host.cappedOutputs.length} available)\n',
            style: HostMessageStyle.warning);
        return;
      }
      final o = host.cappedOutputs[index];
      await runToolOutputViewer(
        screen: screen,
        editor: editor,
        title: 'output · ${o.toolName}',
        text: o.text,
      );
    };
    // `/workflow new` + `/workflow edit` — visual node editor.
    controller.openWorkflowEditor = ({name, isNew = false}) async {
      Graph graph;
      if (isNew) {
        // Seed a minimal runnable skeleton: start → exit, ready to insert into.
        graph = Graph(name: 'workflow', nodes: {
          'start': PipelineNode(id: 'start', attrs: {'shape': 'Mdiamond', 'label': 'Start'}),
          'exit': PipelineNode(id: 'exit', attrs: {'shape': 'Msquare', 'label': 'Done'}),
        }, edges: [
          PipelineEdge(from: 'start', to: 'exit'),
        ]);
      } else {
        final n = name;
        if (n == null) return;
        try {
          graph = parseDot(await PipelineRunner.readWorkflow(workflowsDir, n));
        } catch (e) {
          controller.active.host
              .showMessage('$e\n', style: HostMessageStyle.error);
          return;
        }
      }
      await runWorkflowEditor(
        screen: screen,
        editor: editor,
        graph: graph,
        name: name,
        pipeline: pipeline,
        workflowsDir: workflowsDir,
        isNew: isNew,
      );
    };
    // `/settings`: open the index menu of independently-saved subpanels
    // (providers/models, tiers/roles, token quota, theme) pre-filled with the
    // current config. Each panel writes its own slice on exit; the message
    // reflects whether the last-opened panel changed anything.
    controller.openSettings = () async {
      final envMap = app.environment.env;
      final host = sessionManager.activeConversation.host;
      UserConfig? wrote;
      try {
        wrote = await runSettingsPanel(
          screen: screen,
          editor: editor,
          registry: scheduler.registry,
          env: envMap,
        );
      } on ConfigWriteException catch (e) {
        // Backstop: most subpanels surface write errors in-modal, but a panel
        // that writes after its overlay closes (e.g. theme) escapes here. Never
        // let a read-only config crash the app over a settings edit.
        host.showMessage('$e\n', style: HostMessageStyle.warning);
        return;
      }
      if (wrote != null) {
        host.showMessage(
          'Settings saved to ~/.tina/config — restart tina to apply '
          '(/exit, then re-launch; /resume or -c to return).\n',
          style: HostMessageStyle.success,
        );
      } else {
        host.showMessage('(settings unchanged)\n', style: HostMessageStyle.dim);
      }
    };

    // `/prompts`: open the system-prompt editor pre-filled with the current
    // overrides. Writes on close if anything changed; applies on restart.
    controller.openPrompts = () async {
      final envMap = app.environment.env;
      final host = sessionManager.activeConversation.host;
      UserConfig? wrote;
      try {
        wrote = await runPromptsOverlay(
          screen: screen,
          editor: editor,
          pipeline: pipeline,
          env: envMap,
          initial: loadUserConfig(env: envMap),
        );
      } on ConfigWriteException catch (e) {
        host.showMessage('$e\n', style: HostMessageStyle.warning);
        return;
      }
      if (wrote != null) {
        host.showMessage(
          'Prompts saved to ~/.tina/config — restart tina to apply '
          '(/exit, then re-launch; /resume or -c to return).\n',
          style: HostMessageStyle.success,
        );
      } else {
        host.showMessage('(prompts unchanged)\n', style: HostMessageStyle.dim);
      }
    };

    // `/image <path>` and the `render_image` agent tool share this render core.
    // It decodes the image, fits it to the focused panel's interior and blits it
    // via [Screen.renderImageAbsolute] (pixel-protocol on a capable terminal, a
    // dimmed ▣ placeholder otherwise).  Returns an error message on failure, or
    // null on success (a one-shot paint — streaming chat or /clear repaints over
    // it, which is fine for "look at this image").
    Future<String?> renderImageToPanel(String path) async {
      final resolved = p.isAbsolute(path) ? path : p.join(Directory.current.path, path);
      final file = File(resolved);
      if (!file.existsSync()) return 'no such file: $path';
      final bytes = file.readAsBytesSync();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return 'could not decode image: $path';

      // Resolve the focused panel and its interior cell rectangle.
      final focused = focusManager.focused;
      final panel = focused is PanelFrame ? focused : primaryPanel;
      final interior = panel.bounds;
      if (interior.width < 3 || interior.height < 3) return null;
      final maxCols = interior.width - 2; // inset for the self-drawn border
      // Fit to the interior cell budget.  Terminal pixel geometry (exact
      // pixels-per-cell) is only known on the live libnotcurses path, so we use
      // a representative estimate: block blitters (NCBLIT_3x2, braille) pack a
      // few source pixels per cell, while pixel protocols scale freely.  6 px/cell
      // is a reasonable middle ground that keeps the image a sensible size and
      // within the interior width on the common block-blinker terminals.
      const pxPerCell = 6;
      final dispW = (maxCols * pxPerCell).clamp(1, decoded.width);
      final aspect = decoded.height / decoded.width;
      var dispH = (dispW * aspect).round();
      if (dispH < 1) dispH = 1;
      final fitted = img.copyResize(decoded,
          width: dispW, height: dispH, interpolation: img.Interpolation.average);
      final rgba = Uint32List.fromList(fitted.getBytes(order: img.ChannelOrder.rgba));

      // Paint above the input row (bottom interior row) so the prompt is usable.
      final bottomMargin = panel.inputRect.isEmpty ? 2 : 1;
      final row = interior.bottom - bottomMargin - dispH;
      final col = interior.col + 1;
      // Parent the image onto the focused panel's chat plane (Phase 3): the
      // picture then stacks above that panel's streaming chat surface instead
      // of underneath it on the standard plane.  input/overlay planes stay
      // above via raiseOverlays, so the prompt and popups remain in front.
      final BackendSurface? targetSurface =
          contentCoordinator.surfaceOf(panel.conversationId);
      final render = (int r) => screen.renderImageAbsolute(
          row: r,
          col: col,
          rgba: rgba,
          width: dispW,
          height: dispH,
          maxCols: maxCols,
          targetSurface: targetSurface);
      if (row <= interior.row) {
        // Image taller than the interior — anchor at the top rather than underflow.
        render(interior.row + 1);
        return null;
      }
      render(row);
      return null;
    }

    controller.openImage = (path) async {
      final error = await renderImageToPanel(path);
      if (error != null) {
        sessionManager.activeConversation.host.showMessage(
          '$error\n',
          style: HostMessageStyle.error,
        );
      }
    };

    // The `render_image` agent tool shares the same render path as /image.
    ImageRenderer.coordinate(renderImageToPanel);

    // The spawned-panel tree: parent links + base labels + ordering. A
    // standalone object (not instance state) so these static-create closures
    // can populate + query it via this captured local.
    final tree = SpawnTree(rootId: initialConversationId);

    // Owns panel geometry, the focus ring, and shared-input relocation. Built
    // here (a create-local like [tree]) and passed to the constructor so
    // [run]'s resize handler reaches it via the [panelManager] field.
    final panelManager = PanelManager(
      screen: screen,
      focusManager: focusManager,
      editor: editor,
      primaryFrame: primaryPanel,
      terminalGeometry: geometry,
      menuBarEnabled: _menuBarEnabled,
      tree: tree,
    );
    hasSidePanels = () => panelManager.spawnedFrames.isNotEmpty;

    // The single place that knows about both panels and conversations: the
    // conversation→frame mapping, content relay, focus→active wiring, and the
    // inverted host busy cue. Built here (a create-local like [panelManager]) and
    // passed to the constructor so [run] can relay content and repoint the input
    // after resize. The primary binding also wires the primary host's busy cue.
    contentCoordinator = ConversationPanelCoordinator(
      panelManager: panelManager,
      sessionManager: sessionManager,
      editor: editor,
      primaryHost: initialHost,
    );
    contentCoordinator.bindPrimary(conversationId: initialConversationId);
    // Repoint the forward-declared [relocateInput] at the coordinator, which
    // resolves the active frame and performs the content-agnostic retarget.
    relocateInput = contentCoordinator.relocateInput;

    // Ctrl+O maximizes the highlighted (cycling) or focused panel: its
    // transcript renders as a 2/3-screen popup over a dimmed background. Only
    // conversation-backed panels qualify — a frame with no chat binding falls
    // through and the key reaches its usual handlers.
    editor.onMaximizeToggle = () {
      final frame = focusManager.highlighted ?? focusManager.focused;
      if (frame is! PanelFrame) return false;
      final src = contentCoordinator.chatFor(frame);
      if (src == null) return false;
      unawaited(runMaximizedPanelOverlay(
        screen: screen,
        editor: editor,
        title: src.$2,
        chat: src.$1,
        onClosed: contentCoordinator.repaintAll,
      ));
      return true;
    };

    // Owns the canonical resize sequence. Every resize site (SIGWINCH handler,
    // the three first-spawn blocks, first-paint) repoints at
    // [ResizeCoordinator.handleResize], so the order lives in one place. Constructed
    // here (before the spawn closures) so they can capture it; also threaded to
    // the constructor as [_resizeCoordinator] so [run]'s SIGWINCH handler can reach
    // it from the instance method.
    //
    // Content relay and input relocation are now owned by the
    // [ConversationPanelCoordinator], so the resize sequence repoints at its
    // methods instead of the create-local closures it replaced.
    final resizeCoordinator = ResizeCoordinator(
      sessionManager: sessionManager,
      menuBar: menuBar,
      editor: editor,
      panelManager: panelManager,
      relayContent: contentCoordinator.relayContent,
      relocateInput: contentCoordinator.relocateInput,
    );

    /// Create a detached chat region + host for a spawned side panel — the
    /// shared preamble of `/spawn`, `/branch`, and the delegated-sub-agent
    /// persistence hook. The region is born at the right-column interior and
    /// detached; its geometry is corrected to the panel's tile by
    /// [_buildSpawnPanel]'s `relayContent` (and kept in sync by Phase 1's
    /// surface tracking). Centralized so every spawn site gets the same
    /// detach-then-relay sequence and a future site can't drift.
    TuiConversationHost _makeSpawnedHost(String conversationId) {
      final chat =
          ScrollingTextRegion(screen, bounds: screen.layout.info)..detach();
      return TuiConversationHost(
        conversationId: conversationId,
        chat: chat,
        spinner: Spinner(enabled: false),
        screen: screen,
        editor: editor,
        active: false,
        primary: false,
      );
    }

    /// Create the [PanelFrame] for a spawned conversation, wire the
    /// provided [sinkHost] (the agent/sub-agent writes into it), register it in
    /// spawnedPanels/focusManager/tree, split the layout on the first one, and
    /// relayout. Shared by restore (`panelizeRestoredConversation`) and live
    /// delegated-sub-agent panelization (the persistence hook). Returns the panel.
    PanelFrame _buildSpawnPanel({
      required String conversationId,
      required String parentConversationId,
      required String label,
      required TuiConversationHost sinkHost,
    }) {
      // Record the tree edge so the layout nests this panel under its parent
      // (the primary when it was a direct spawn, else its spawner) and indents
      // it by depth (Phase 1).
      tree.parentOf[conversationId] = parentConversationId;
      tree.baseLabel[conversationId] = label;

      // First panel: split the layout to make a right column (mirrors the
      // openSpawn first-spawn block). Read empty BEFORE adding — this is the
      // "is this the first panel" check. The canonical sequence lives in
      // [ResizeCoordinator.handleResize]; set stayAttachedWhenInactive first
      // (first-spawn-specific), then repoint at it.
      if (!panelManager.hasSpawnedFrames) {
        initialHost.stayAttachedWhenInactive = true;
        resizeCoordinator.handleResize(split: true, drawInfoFrame: false);
      }

      // Bind the conversation to a frame (content adapter, focus, busy cue) and
      // register it in the tiling list + focus ring. The coordinator owns
      // focus→active wiring; sub-agent panels re-point it later once their
      // Conversation is minted.
      final panel = contentCoordinator.bindSpawned(host: sinkHost, label: label);
      panelManager.layout();
      contentCoordinator.relayContent();
      return panel;
    }

    // A live view of one background workflow run, opened when the agent
    // launches a workflow (the supervisor's onLaunch hook). The panel is an
    // "extra" — a read-only [RunPanelContent] transcript in a spawned-style
    // frame — auto-opened WITHOUT stealing input focus (the chat keeps the
    // draft). The run's stream (node text + progress) is rerouted to the
    // panel's own host ([WorkflowRun.sink]), so the panel shows the run's
    // chat-style transcript and the chat stays clean. Keys while the panel is
    // focused: `s` stops the run, `x` closes the panel (the run itself
    // continues unless stopped), PgUp/PgDn scroll the transcript. Input is
    // disabled — the frame never binds the shared editor.
    final Map<String,
            ({PanelFrame frame, RunPanelContent content, TuiConversationHost host})>
        runPanels = {};

    void _closeRunPanel(String runId) {
      final handle = runPanels.remove(runId);
      if (handle == null) return;
      // Drop the hooks first so a late event can't repaint a torn-down panel
      // (the frame is gone; its geometry is stale).
      handle.frame.onPanelKey = null;
      handle.frame.onScroll = null;
      handle.frame.onWheel = null;
      handle.host.chat.onScrollbackChanged = null;
      supervisor.find(runId)?.onFinished = null;
      handle.content.detach();
      contentCoordinator.unbindExtra(handle.frame);
      tree.parentOf.remove(handle.frame.conversationId);
      tree.baseLabel.remove(handle.frame.conversationId);
      panelManager.removeFrame(handle.frame);
      if (!panelManager.hasSpawnedFrames) {
        // Last panel: unsplit back to the full-width primary (mirror of the
        // first-panel split).
        initialHost.stayAttachedWhenInactive = false;
        resizeCoordinator.handleResize(split: false, drawInfoFrame: true);
      } else {
        panelManager.layout();
        contentCoordinator.relayContent();
      }
      // The run continues streaming into the detached region until it ends;
      // the transcript buffers there and is discarded with the region.
    }

    /// Open the run's live transcript panel. SYNCHRONOUS: it runs inside the
    /// supervisor's `onLaunch` hook, before the run's stream can start, so
    /// [WorkflowRun.sink] is installed before any node can emit.
    void _openRunPanel(WorkflowRun run) {
      // The run's stream sink: a spawned-style host whose region renders in
      // this panel. Node text + progress land here instead of the chat.
      final host = _makeSpawnedHost('wf-run-${run.id}');
      run.sink = host;

      // First panel: split the layout to make a right column (mirrors
      // _buildSpawnPanel's first-panel block).
      if (!panelManager.hasSpawnedFrames) {
        initialHost.stayAttachedWhenInactive = true;
        resizeCoordinator.handleResize(split: true, drawInfoFrame: false);
      }

      final frame = PanelFrame(
        screen: screen,
        label: 'wf ${run.workflowName} [run ${run.id}]',
        conversationId: 'wf-run-${run.id}',
        ownsCanvas: false,
      );
      tree.parentOf[frame.conversationId] = tree.rootId; // depth-1, flush
      tree.baseLabel[frame.conversationId] = frame.label;
      final content = RunPanelContent(screen: screen, chat: host.chat);
      contentCoordinator.bindExtra(frame: frame, content: content);
      panelManager.layout();
      contentCoordinator.relayContent();
      // Scrollback: PgUp/PgDn + the mouse wheel scroll the transcript; the
      // frame badge shows lines that arrived while scrolled up (mirrors
      // _wireScrollback).
      frame.onScroll = (deltaPages) {
        final page = host.chat.usableHeight;
        host.chat.scrollBy(deltaPages * (page > 0 ? page : 1));
      };
      frame.onWheel = (deltaRows) => host.chat.scrollBy(deltaRows);
      host.chat.onScrollbackChanged = () {
        frame.setScrollBadge(host.chat.newWhileScrolled);
      };
      // The comet sweeps the rails while the run is in flight.
      frame.setBusy(run.isRunning);
      // Read-only like the environment panel (see
      // ConversationPanelCoordinator._wireReadOnlyInput): text keystrokes are
      // consumed with a one-time notice instead of falling through to the
      // shared editor, where they would silently type into the main
      // conversation. s/x keep their meaning; navigation passes through.
      var inputNoticeShown = false;
      frame.onPanelKey = (ev) {
        if (ev is CharInput && ev.text == 's') {
          supervisor.stop(run.id);
          return true;
        }
        if (ev is CharInput && ev.text == 'x') {
          _closeRunPanel(run.id);
          return true;
        }
        final isText = ev is CharInput ||
            ev is PasteInput ||
            ev is EditingKey ||
            (ev is ControlKey && ev.code == ControlCode.enter);
        if (!isText) {
          // Arrows/PgUp/PgDn are not consumed here — PgUp/PgDn reach the
          // frame's scroll hook above; arrow keys do nothing (there is
          // nothing to pan). Esc/Ctrl+C/Alt also fall through to the editor.
          return false;
        }
        if (!inputNoticeShown) {
          inputNoticeShown = true;
          host.showMessage(
            '(input disabled — read-only run panel; s stops the run, x '
            'closes it; cycle focus back to a chat panel to type)\n',
            style: HostMessageStyle.dim,
          );
        }
        return true;
      };
      // Completion settles the comet; the transcript already ends with the
      // engine's ✔/✖ workflow complete/failed line.
      run.onFinished = () => frame.setBusy(false);
      runPanels[run.id] = (frame: frame, content: content, host: host);
    }

    // Wire the supervisor's onLaunch hook to the run-panel opener.
    handleWorkflowLaunch = _openRunPanel;

    // Persist sub-agent transcripts as their own conversations AND, for agent-
    // role jobs, live-panelize them so a delegated sub-agent appears as a panel
    // under its parent (Phase 2). The factory closes over the store + UI. It
    // mints a `subAgent` conversation + recorder (best-effort: a store failure
    // leaves conversationId null and the job falls back to telemetry-only
    // streaming), and — when minting succeeds — builds the panel + a BusSink
    // over its host and stashes that sink on the job so _runAgent streams into
    // the panel.
    //
    // On a fresh run the primary session is a placeholder id that does NOT exist
    // in the store yet (the recorder creates the on-disk entries lazily on the
    // first append). createConversationWithMeta throws `Session not found` for a
    // missing session, so we must materialize the primary first — exactly the
    // /spawn path — and use the recorder's real on-disk session id (which
    // diverges from the in-memory placeholder id until the primary's first
    // write). Without this guard the throw is swallowed by _persistJob and the
    // job silently falls back to telemetry-only streaming: the delegation runs
    // but no panel ever opens.
    scheduler.persistence = (job, {required meta, required parentConversationId}) async {
      await initialRecorder.ensureRegistered();
      final sessionId = initialRecorder.sessionId;
      final conversationId =
          await store.createConversationWithMeta(sessionId, meta);
      // providerId is recorded in the session manifest on first write; derive it
      // from the model ref's prefix (always present — "provider/model").
      final model = meta.model ?? '${config.provider}/unknown';
      final providerId = model.contains('/') ? model.split('/').first : model;
      final recorder = SessionRecorder(store, sessionId, conversationId,
          providerId: providerId);
      recorder.attach(sessionId, conversationId);

      if (conversationId.isNotEmpty) {
        final host = _makeSpawnedHost(conversationId);
        final panel = _buildSpawnPanel(
          conversationId: conversationId,
          parentConversationId: parentConversationId,
          label: panelLabel(role: meta.targetName ?? job.label, model: model),
          sinkHost: host,
        );
        // Stash the host (as the abstract HostInterface) so the scheduler can
        // build its sub-agent Conversation against it. Focus is already wired by
        // [ConversationPanelCoordinator.bindSpawned] (resolved by conversationId
        // at focus time), but the engine reads [SubAgentJob.wirePanelFocus] as
        // non-null — keep it assigned (never invoked) to satisfy that contract.
        job.panelHost = host;
        job.wirePanelFocus = (onFocus) => panel.onFocus = onFocus;
        // Wrap the panel host in a BusSink so the sub-agent streams into the
        // panel AND keeps emitting to job._bus (parent's «label: → …» progress
        // + read() both stay working).
        job.panelSink = BusSink(host, job.eventBus);
      }
      return (conversationId, recorder);
    };

    // Phase 3 — full unification: a live-panelized delegated sub-agent becomes a
    // first-class session. The factory builds its Agent with the panel host's
    // asker (so tool calls on the focused panel surface permission prompts) and
    // registers a real Conversation. The panel's focus was already wired by
    // [ConversationPanelCoordinator.bindSpawned] in the persistence hook (resolved
    // by id at focus time), so focusing the panel makes it the active input
    // target — exactly like a /spawn panel. Returns the Agent for the
    // scheduler's loop.
    scheduler.subAgentSessionFactory = (scheduler, job,
            {required provider,
            required tools,
            required policy,
            required sink,
            required host,
            required recorder,
            required conversationId,
            required label,
            system,
            maxSteps,
            budget,
            pauseGate,
            required wirePanelFocus}) {
      final agent = Agent(
        provider: provider,
        tools: tools,
        sink: sink,
        policy: policy,
        asker: host.askPermission,
        maxSteps: maxSteps ?? scheduler.defaultMaxSteps,
        budget: budget,
        pauseGate: pauseGate,
        system: system ?? '',
      );
      final conv = Conversation(
        id: conversationId,
        label: label,
        agent: agent,
        provider: provider,
        host: host,
        policy: policy,
        recorder: recorder,
      );
      sessionManager.active.addConversation(conv);
      // The panel's focus was already wired by
      // [ConversationPanelCoordinator.bindSpawned] when the panel was built in
      // the persistence hook — it resolves to this conversation (by id) at focus
      // time, so the old placeholder-then-repoint dance is obsolete. The
      // [wirePanelFocus] param is part of the engine contract but unused here.
      return agent;
    };

    // Wrap an already-restored [conv] in a [PanelFrame] tiled in the right
    // column and make it the focus target. Mirrors the tail of openSpawn (the
    // register/layout/focus block): the Conversation + agent are already rebuilt
    // by restoreConversation; this only adds the missing panel chrome.
    //
    // The restored host's chat was created with no bounds override, so a panel
    // couldn't reposition it (setBounds no-ops without one). Give it the right-
    // column info rect first — the layout closure then refines it into the tiled
    // slot and attach() makes the buffered history visible.
    void panelizeRestoredConversation(Conversation conv,
        {required String? parentId}) {
      final host = conv.host as TuiConversationHost;
      _buildSpawnPanel(
        conversationId: conv.id,
        parentConversationId: parentId ?? initialConversationId,
        label: restoredLabelOf[conv.id] ?? conv.label,
        sinkHost: host,
      );
    }

    // Panelize the restored non-primary conversations (collected above before
    // the infra existed). Panelize FIRST so the chat region is sized into its
    // right-column slot, then replay the transcript into it.
    for (final conv in restoredPanels) {
      panelizeRestoredConversation(conv,
          parentId: restoredParentOf[conv.id]);
      if (conv.history.isNotEmpty) replayHistory(conv.host, conv.history);
    }

    // The shared `/spawn` + `/branch` flow: model-picker then tool-profile
    // picker. Both commands present the identical overlay sequence (per the
    // "same as spawn" requirement on `/branch`); they only diverge once a
    // target is chosen. Returns the chosen (modelRef, profile) or null if
    // either overlay is cancelled — the caller treats null as "no action".
    Future<({String ref, ToolProfile profile})?> pickSpawnedTarget() async {
      final envMap = app.environment.env;
      final cfg = loadUserConfig(env: envMap);
      final configured = cfg.providers.keys.toSet();
      if (configured.isEmpty) {
        sessionManager.activeConversation.host.showMessage(
          'No providers configured yet — use /settings first.\n',
          style: HostMessageStyle.warning,
        );
        return null;
      }
      final disabledModelRefs = <String>{};
      for (final e in cfg.providers.entries) {
        for (final mid in (e.value.disabledModels ?? const <String>[])) {
          disabledModelRefs.add('${e.key}/$mid');
        }
      }
      final selected = await runSpawnOverlay(
        screen: screen,
        editor: editor,
        registry: scheduler.registry,
        configuredProviders: configured,
        disabledModelRefs: disabledModelRefs,
        recentlyUsed: loadSpawnMru(env: envMap),
      );
      if (selected == null) return null;
      recordSpawnMru(selected, env: envMap);

      // Pick the panel's tool profile. Cancel here aborts the spawn (the model
      // was chosen but no agent yet). The panel's identity is the entry agent's.
      final profile = await runToolProfileOverlay(
        screen: screen,
        editor: editor,
      );
      if (profile == null) return null;
      return (ref: selected, profile: profile);
    }

    // Resolve the model+profile picker once: an injected [spawnTargetPicker]
    // (tests) short-circuits the terminal overlays; otherwise the real
    // [pickSpawnedTarget] runs the spawn-style overlay sequence. Both `/spawn`
    // and `/branch` capture this local.
    final pickTarget = spawnTargetPicker ?? pickSpawnedTarget;

    // `/spawn`: pick a model and add a real (no-tool) Conversation rendered as
    // a focusable panel in the right column. Splits the layout to make room.
    controller.openSpawn = () async {
      final pick = await pickTarget();
      if (pick == null) return;
      final selected = pick.ref;
      final profile = pick.profile;

      // The shared helper loaded the user config internally; load it again for
      // the spawn-side provider + prompt assembly below (cheap, reused by the
      // model-picker cache).
      final envMap = app.environment.env;
      final cfg = loadUserConfig(env: envMap);

      // Split the layout on the first spawned panel; the primary stays visible
      // (its host won't detach while spawned panels share the screen). The
      // canonical sequence lives in [ResizeCoordinator.handleResize]; set
      // stayAttachedWhenInactive first (first-spawn-specific), then repoint.
      if (!panelManager.hasSpawnedFrames) {
        initialHost.stayAttachedWhenInactive = true;
        resizeCoordinator.handleResize(split: true, drawInfoFrame: false);
      }

      // Build the no-tool provider for the picked model.
      final slash = selected.indexOf('/');
      final providerId = slash >= 0 ? selected.substring(0, slash) : '';
      final apiKeyOverride = cfg.providers[providerId]?.apiKey;
      final LlmProvider spawnProvider;
      try {
        spawnProvider = scheduler.registry.build(
          selected,
          apiKeyOverride: apiKeyOverride,
          maxTokens: 512,
          requestTimeout: config.requestTimeout,
        );
      } catch (e) {
        sessionManager.activeConversation.host.showMessage(
          'error: failed to build provider: $e\n',
          style: HostMessageStyle.error,
        );
        return;
      }

      // Derive the agent from the chosen tool profile: its tool set (the
      // spawned panel runs under the entry agent's identity, honoring any
      // [prompts.main] override) and a policy that allows exactly those tools so
      // the side panel never prompts for them. --safe-mode: drop write/edit/bash
      // from the spawned side panel too.
      final eff = config.safeMode
          ? stripForSafeMode(toolSetFor(profile))
          : toolSetFor(profile);
      final spawnSystem = resolveMainPrompt(pipeline,
          overrides: cfg.prompts,
          safeMode: config.safeMode,
          loadProjectContext: pipeline.loadProjectContext);
      final profileToolNames = eff.map((t) => t.schema.name).toList();
      final spawnTools = ToolRegistry(eff);
      // Profile tools are pre-approved, EXCEPT bash: it's the uncontained
      // destructive vector, so it inherits the user's bash decision (ask → the
      // panel prompts; allow under --yolo/--allow bash:…; deny under --deny).
      final bashDecision = config.buildPolicy().check('bash', const {});
      final spawnPolicy = PermissionPolicy(rules: [
        for (final n in profileToolNames)
          if (n != 'bash')
            PermissionRule(
                toolName: n, pattern: '*', decision: PermissionDecision.allow),
        if (profileToolNames.contains('bash'))
          PermissionRule(toolName: 'bash', pattern: '*', decision: bashDecision),
      ]);

      // Register the spawn in the session manifest — this mints the
      // conversation id AND records the spawn meta (role, model, policy, system
      // prompt, parent link) so the side panel is rebuilt on resume. The
      // recorder's _lazyInit only registers meta for a brand-new session; since
      // the primary session already exists, an explicit call is required.
      //
      // A fresh session persists lazily, so its directory may not exist yet
      // when /spawn is the first action (or before the primary's first write
      // resolves). createConversationWithMeta throws on a missing session, so
      // materialize the primary session first — a no-op once it has written.
      // The spawn must live in the SAME on-disk session as the primary. The
      // primary always persists through initialRecorder, whose session id is
      // therefore the source of truth: on a fresh start the on-disk id is
      // minted at first-write time and diverges from the in-memory placeholder
      // (sessionManager.active.id), so we must not use the latter here.
      await initialRecorder.ensureRegistered();
      final spawnSessionId = initialRecorder.sessionId;
      final chatId = await store.createConversationWithMeta(
        spawnSessionId,
        ConversationMetaInput.spawn(
          providerId: providerId,
          providerModel: spawnProvider.model,
          policy: spawnPolicy,
          systemPrompt: spawnSystem,
          targetName: profile.name,
          parentConversationId: sessionManager.activeConversationId,
        ),
      );
      // Record the tree edge so the layout can nest this panel under its parent
      // (the focused conversation at spawn time) and indent it by depth.
      tree.parentOf[chatId] = sessionManager.activeConversationId;
      tree.baseLabel[chatId] = panelLabel(role: profile.name, model: selected);
      // Bounded chat region for the side column, detached until laid out.
      final host = _makeSpawnedHost(chatId);
      final spawnAgent = Agent(
        provider: spawnProvider,
        tools: spawnTools,
        sink: host,
        policy: spawnPolicy,
        asker: host.askPermission,
        system: spawnSystem,
        pauseGate: scheduler.pauseGate,
        maxSteps: 50,
      );
      // Point a recorder at the already-registered conversation so the side
      // panel's transcript is persisted into the real file. The conversation
      // meta was written above via createConversationWithMeta, so attach()
      // (not _lazyInit) points the recorder at the existing file — subsequent
      // appends from the session controller write it automatically.
      final spawnRecorder =
          SessionRecorder(store, spawnSessionId, chatId, providerId: providerId);
      spawnRecorder.attach(spawnSessionId, chatId);
      final conv = Conversation(
        id: chatId,
        label: '${profile.name} (${selected})',
        agent: spawnAgent,
        provider: spawnProvider,
        host: host,
        policy: spawnPolicy,
        recorder: spawnRecorder,
      );
      sessionManager.active.addConversation(conv);
      // Bind the conversation to a frame (chrome, content adapter, focus, busy
      // cue) and register it in the tiling list + focus ring. Focus resolves to
      // this conversation (by id) at focus time via the coordinator.
      final panel = contentCoordinator.bindSpawned(
          host: host, label: panelLabel(role: profile.name, model: selected));

      panelManager.layout();
      contentCoordinator.relayContent();
      focusManager.focusPanel(panel);
    };

    // `/branch`: fork the active conversation into a brand-new side panel. Runs
    // the SAME model+role overlay sequence as `/spawn` (via pickSpawnedTarget),
    // then creates a new conversation whose transcript is a copy of the parent's
    // history. The parent is left untouched — only focus moves to the branch,
    // and the secondary host's focus wiring (resolved by id) keeps the manifest
    // anchor on the primary (persist:false) — and the branch persists under its own id in the same session so
    // it resumes (kind=branch, parentConversationId set) with the fork history.
    controller.openBranch = () async {
      final pick = await pickTarget();
      if (pick == null) return;
      final selected = pick.ref;
      final profile = pick.profile;

      // Split the layout on the first branched panel, exactly like /spawn. The
      // canonical sequence lives in [ResizeCoordinator.handleResize]; set
      // stayAttachedWhenInactive first (first-spawn-specific), then repoint.
      if (!panelManager.hasSpawnedFrames) {
        initialHost.stayAttachedWhenInactive = true;
        resizeCoordinator.handleResize(split: true, drawInfoFrame: false);
      }

      // Build the provider for the picked model (mirrors /spawn).
      final slash = selected.indexOf('/');
      final providerId = slash >= 0 ? selected.substring(0, slash) : '';
      final envMap = app.environment.env;
      final cfg = loadUserConfig(env: envMap);
      final apiKeyOverride = cfg.providers[providerId]?.apiKey;
      final LlmProvider branchProvider;
      try {
        branchProvider = scheduler.registry.build(
          selected,
          apiKeyOverride: apiKeyOverride,
          maxTokens: 512,
          requestTimeout: config.requestTimeout,
        );
      } catch (e) {
        sessionManager.activeConversation.host.showMessage(
          'error: failed to build provider: $e\n',
          style: HostMessageStyle.error,
        );
        return;
      }

      // Derive the agent from the chosen tool profile (mirrors /spawn).
      final eff = config.safeMode
          ? stripForSafeMode(toolSetFor(profile))
          : toolSetFor(profile);
      final branchSystem = resolveMainPrompt(pipeline,
          overrides: cfg.prompts,
          safeMode: config.safeMode,
          loadProjectContext: pipeline.loadProjectContext);
      final profileToolNames = eff.map((t) => t.schema.name).toList();
      final branchTools = ToolRegistry(eff);
      // As with /spawn: profile tools pre-approved except bash, which inherits
      // the user's bash decision (ask → prompt; allow under --yolo; deny …).
      final bashDecision = config.buildPolicy().check('bash', const {});
      final branchPolicy = PermissionPolicy(rules: [
        for (final n in profileToolNames)
          if (n != 'bash')
            PermissionRule(
                toolName: n, pattern: '*', decision: PermissionDecision.allow),
        if (profileToolNames.contains('bash'))
          PermissionRule(toolName: 'bash', pattern: '*', decision: bashDecision),
      ]);

      // Register the branch in the session manifest, exactly as /spawn does —
      // minting a new conversation id and recording the branch meta (role,
      // model, policy, system prompt, parent link). Materialize the primary
      // session first on the lazy-start path. Documented at the /spawn
      // createConversationWithMeta block: the branch lives in the SAME on-disk
      // session as the primary, and initialRecorder.sessionId is the source of
      // truth for that id.
      await initialRecorder.ensureRegistered();
      final branchSessionId = initialRecorder.sessionId;
      final branchMeta = ConversationMetaInput.branch(
        providerId: providerId,
        providerModel: branchProvider.model,
        policy: branchPolicy,
        systemPrompt: branchSystem,
        targetName: profile.name,
        parentConversationId: sessionManager.activeConversationId,
      );
      final chatId =
          await store.createConversationWithMeta(branchSessionId, branchMeta);
      tree.parentOf[chatId] = sessionManager.activeConversationId;
      tree.baseLabel[chatId] = panelLabel(role: profile.name, model: selected);

      // Build the panel + host via the shared spawn/branch helper. The parent
      // is read here (its history) but never mutated — .toList() copies, and the
      // on-disk write below is a separate file.
      final parent = sessionManager.activeConversation;
      final host = _makeSpawnedHost(chatId);
      // conv is built below (it owns the conversation we focus), but focus is
      // resolved by id at focus time via the coordinator, so no rebind is
      // needed after conv exists.
      final panel = _buildSpawnPanel(
        conversationId: chatId,
        parentConversationId: sessionManager.activeConversationId,
        label: panelLabel(role: profile.name, model: selected),
        sinkHost: host,
      );

      // Point a recorder at the already-registered conversation, then write the
      // forked history into its .jsonl. The meta was written above via
      // createConversationWithMeta, so attach() (not _lazyInit) points the
      // recorder at the existing file. replace() atomically seeds the file with
      // a copy of the parent's messages so the branch is resumable with the
      // fork — and independent of the parent from here on.
      final branchRecorder =
          SessionRecorder(store, branchSessionId, chatId, providerId: providerId);
      branchRecorder.attach(branchSessionId, chatId);
      await branchRecorder.replace(parent.history.toList());

      final conv = Conversation(
        id: chatId,
        label: '${profile.name} (${selected})',
        agent: Agent(
          provider: branchProvider,
          tools: branchTools,
          sink: host,
          policy: branchPolicy,
          asker: host.askPermission,
          system: branchSystem,
          pauseGate: scheduler.pauseGate,
          maxSteps: 50,
        ),
        provider: branchProvider,
        host: host,
        policy: branchPolicy,
        recorder: branchRecorder,
        // Seed the in-memory history with the parent's turns so the live panel
        // renders the fork immediately; the on-disk .jsonl written above makes
        // resume find them too. A fresh copy — never the parent's list.
        initialHistory: parent.history.toList(),
      );

      sessionManager.active.addConversation(conv);
      // Paint the forked history into the panel's chat region — `initialHistory`
      // above only seeds the Conversation's in-memory list (and the .jsonl);
      // it does NOT render anything. Without this, the branch carries the
      // parent's turns (sends to the model, persists) but the panel is blank
      // until the first live turn. Mirrors the restore path (line ~926).
      if (conv.history.isNotEmpty) replayHistory(conv.host, conv.history);
      // The panel's focus was already wired by bindSpawned when the panel was
      // built — it resolves to this branch conversation (by id) at focus time,
      // leaving the manifest anchor on the parent (secondary host → persist:false).
      focusManager.focusPanel(panel);
    };

    // `/model`: pick a provider/model and switch the active conversation to it.
    controller.openModelPicker = () async {
      final envMap = app.environment.env;
      final cfg = loadUserConfig(env: envMap);
      final configured = cfg.providers.keys.toSet();
      if (configured.isEmpty) {
        sessionManager.activeConversation.host.showMessage(
          'No providers configured yet — use /settings first.\n',
          style: HostMessageStyle.warning,
        );
        return;
      }
      final disabledModelRefs = <String>{};
      for (final e in cfg.providers.entries) {
        for (final mid in (e.value.disabledModels ?? const <String>[])) {
          disabledModelRefs.add('${e.key}/$mid');
        }
      }
      // Build the list of provider/model refs limited to configured providers.
      final refs = <String>[];
      final names = <String, String>{};
      for (final pid in scheduler.registry.providerIds) {
        names[pid] = scheduler.registry.descriptor(pid)?.name ?? pid;
        if (!configured.contains(pid)) continue;
        for (final m in scheduler.registry.modelsFor(pid)) {
          final ref = '$pid/${m.id}';
          if (!disabledModelRefs.contains(ref)) refs.add(ref);
        }
      }
      if (refs.isEmpty) {
        sessionManager.activeConversation.host.showMessage(
          'All models are disabled — enable some in /settings.\n',
          style: HostMessageStyle.warning,
        );
        return;
      }
      final selected = await runModelPickerOverlay(
        screen: screen,
        editor: editor,
        modelRefs: refs,
        title: 'Switch model',
        providerNames: names,
      );
      if (selected == null) return;

      // Parse and build the new provider.
      final slash = selected.indexOf('/');
      final providerId =
          slash >= 0 ? selected.substring(0, slash) : selected;
      final apiKeyOverride = cfg.providers[providerId]?.apiKey;
      final LlmProvider nextProvider;
      try {
        nextProvider = scheduler.registry.build(
          selected,
          apiKeyOverride: apiKeyOverride,
          requestTimeout: config.requestTimeout,
        );
      } catch (e) {
        sessionManager.activeConversation.host.showMessage(
          'error: $e\n',
          style: HostMessageStyle.error,
        );
        return;
      }

      final conv = sessionManager.activeConversation;
      final prev = '${conv.label}';
      // The label is `role (model)`; keep the role, swap only the model.
      final role = prev.contains(' (')
          ? prev.split(' (').first
          : 'main';
      conv.provider = nextProvider;
      conv.label = panelLabel(role: role, model: selected);
      final panel = (conv.host as TuiConversationHost).panel;
      if (panel != null) {
        tree.relabelPanel(panel, conv.label);
      }
      conv.host.showMessage(
        'model: $prev → ${conv.label}\n',
        style: HostMessageStyle.dim,
      );
    };

    // Keep a minimal progress subscription so teardown can cancel it.
    final progressSub = scheduler.events.listen((_) {});

    // Per-session spend trip → pause dialog. Fires from a background event (a
    // sub-agent can trip while the REPL is idle), so the dialog must surface
    // without a turn or slash command to await it — runSpendPauseDialog paints
    // an OverlayRegion and readKey's exclusively (serialized with /settings and
    // askPermission by the editor's readKey mutex). requestPause is idempotent,
    // so this fires once per pause; the guard is belt-and-suspenders.
    var pauseDialogActive = false;
    final pauseGate = app.pauseGate;
    final pauseSub = pauseGate.onPause.listen((reason) async {
      if (pauseDialogActive) return;
      pauseDialogActive = true;
      try {
        final cont = await runSpendPauseDialog(screen: screen, editor: editor);
        pauseGate.resume(continueDecision: cont);
      } finally {
        pauseDialogActive = false;
      }
    });

    final coordinator = TuiCoordinator._(
      config: config,
      provider: provider,
      policy: policy,
      store: store,
      screen: screen,
      editor: editor,
      spinner: spinner,
      sessionManager: sessionManager,
      menuBar: menuBar,
      controller: controller,
      focusManager: focusManager,
      exitSignal: exitCompleter.future,
      subAgentScheduler: scheduler,
      progressSub: progressSub,
      pauseSub: pauseSub,
      terminalGeometry: geometry,
      panelManager: panelManager,
      contentCoordinator: contentCoordinator,
      warning: warning,
      refreshSessionMenu: refreshSessionMenu,
      tree: tree,
      setupOverlay: setupOverlay ??
          () => runSetupOverlay(
                screen: screen,
                editor: editor,
                registry: scheduler.registry,
                env: app.environment.env,
              ),
      resizeCoordinator: resizeCoordinator,
      sessionBar: sessionBar,
    );

    // `/index`: the per-directory summary sidecar service built above (it
    // shares the region registry's allocations, so `/index` covers allocated
    // regions too). The y/n confirm renders as the same arrow-key picker the
    // other choices use (Yes/No entries), not a bare key read.
    controller.summaryIndex = summaryIndex;
    // The environment agent service: `/index`'s environment branch runs it in
    // the background, and first load (below) populates the record.
    final environmentIndex = EnvironmentIndex(
      config: app.config,
      registry: app.registry,
      environment: app.environment,
      projectRoot: Directory.current.path,
      spendLedger: app.spendLedger,
    );
    controller.environmentIndex = environmentIndex;
    // First load: no ENVIRONMENT.md → offer to populate it in the background
    // (docs/proposals/environment_agent.md, "First load"). Interactive only —
    // headless never auto-runs setup — and only for a trusted project (the
    // same gate that withholds AGENTS.md) and not under --safe-mode (a doing
    // worker with no shell is pointless). `[environment] auto_populate`
    // decides how: `ask` (the default) shows a picker — a token-spending
    // agent turn never starts silently — `always` runs without asking,
    // `never` skips. A merely stale record does not auto-run: `/index` flags
    // it and the user decides there.
    //
    // The ask is *recorded* here but *performed* in [run], after the first
    // paint and before the REPL loop takes the keyboard — the picker needs
    // the editor's key stream, which the REPL line loop would otherwise hold
    // ("Stream has already been listened to").
    if (!config.safeMode &&
        pipeline.loadProjectContext &&
        !EnvironmentRecord.exists(Directory.current.path)) {
      coordinator.pendingFirstLoadEnvironmentAsk = () async {
        // The effective model the environment agent runs under for this run:
        // the just-picked ref, else the persisted `[environment] model`, else
        // the shipped default. Passed explicitly (not read from [config])
        // because the in-memory config predates the picker's fresh choice.
        Future<String> pickEnvironmentModel() async {
          final stored = config.environmentModel ?? kDefaultEnvironmentModelRef;
          final envMap = app.environment.env;
          final cfg = loadUserConfig(env: envMap);
          final configured = cfg.providers.keys.toSet();
          if (configured.isEmpty) return stored; // nothing to pick from
          final disabledModelRefs = <String>{};
          for (final e in cfg.providers.entries) {
            for (final mid in (e.value.disabledModels ?? const <String>[])) {
              disabledModelRefs.add('${e.key}/$mid');
            }
          }
          final refs = <String>[];
          for (final pid in scheduler.registry.providerIds) {
            if (!configured.contains(pid)) continue;
            for (final m in scheduler.registry.modelsFor(pid)) {
              final ref = '$pid/${m.id}';
              if (!disabledModelRefs.contains(ref)) refs.add(ref);
            }
          }
          if (refs.isEmpty) return stored;
          // Surface the effective default at the top — the cursor starts on
          // index 0, so the default is also the preselected choice.
          final ordered = [
            if (refs.contains(stored)) stored,
            ...refs.where((r) => r != stored),
          ];
          final selected = await runListOverlay<String>(
            screen: screen,
            editor: editor,
            entries: [
              for (final r in ordered)
                (display: r == stored ? '$r  (default)' : r, value: r),
            ],
            title: 'Environment agent — pick its model',
            footer: '↑↓ move · enter select · esc keep default',
            accent: 'cyan',
            body: 'The environment agent is a one-off side-panel worker that measures '
                'this repo (toolchain, setup, build, tests, auth) and writes '
                'ENVIRONMENT.md. It runs on its own model, separate from the '
                'main conversation.\n'
                '\n'
                'The choice is saved to [environment] model in ~/.tina/config '
                'and reused for later environment runs.',
          );
          final ref = selected ?? stored;
          if (selected != null && selected != cfg.environmentModel) {
            // Best-effort persist (re-loaded fresh so a concurrent
            // auto_populate write in the same ask isn't clobbered).
            try {
              writeUserConfig(
                loadUserConfig(env: envMap)
                    .copyWith(environmentModel: selected),
                env: envMap,
              );
              initialHost.showMessage(
                'Saved: environment agent model → $selected '
                '(`[environment] model` in ~/.tina/config)\n',
                style: HostMessageStyle.dim,
              );
            } catch (_) {}
          }
          return ref;
        }

        Future<void> launch(String envModelRef) async {
          initialHost.showMessage(
            'No ENVIRONMENT.md yet — spawning environment agent in side panel: '
            'read-only scouts will describe the repo root and each top-level '
            'subfolder, then the agent inspects toolchain, runs setup/build/test '
            'and writes .tina/ENVIRONMENT.md (Esc-Esc to cancel)…\n',
          );
          // Spawn a side panel for the environment agent so its work does not clutter the main panel.
          final envConvId = 'env-${DateTime.now().millisecondsSinceEpoch}';
          final envHost = _makeSpawnedHost(envConvId);
          _buildSpawnPanel(
            conversationId: envConvId,
            parentConversationId: initialConversation.id,
            // Every conversation panel names the model it runs under; the
            // environment agent runs on its OWN model ([environment] model,
            // default DiffusionGemma on NIM) — not the session's startup
            // model — so name the ref the run actually uses.
            label: panelLabel(role: 'Environment', model: envModelRef),
            sinkHost: envHost,
          );
          // One scout panel per surveyed folder, nested UNDER the environment
          // panel (depth 2): each folder's read-only scout streams its own
          // transcript (tool reads + description) into its own surface. The
          // panels are host-only (like the env panel itself) — read-only, and
          // they stay after the scout finishes as its transcript.
          var scoutSeq = 0;
          AgentSink scoutPanelSink(String dir) {
            final id = '$envConvId-scout-${scoutSeq++}';
            final host = _makeSpawnedHost(id);
            _buildSpawnPanel(
              conversationId: id,
              parentConversationId: envConvId,
              label: panelLabel(
                  role: dir == '.' ? 'scout root' : 'scout $dir',
                  model: envModelRef),
              sinkHost: host,
            );
            return host;
          }
          final cancel = Completer<void>();
          // The env panel's host is a BACKGROUND host — its own asker
          // auto-denies, which would silently starve the ceremony of every
          // gated tool (bash/write/edit all "denied", nothing ever sticks).
          // Route its permission asks through the attention queue instead:
          // the prompt renders in the env panel, the y/n/a/d key is read via
          // the shared editor — the same seam workflow run panels use.
          final envAsker = WorkflowPermissionAsker(
            sink: envHost,
            screen: screen,
            editor: editor,
            attentionQueue: attentionQueue,
          );
          // Esc-Esc cancels the in-flight environment run. The main REPL remains responsive.
          // For simplicity we bind cancellation to the initial conversation's host busy state;
          // the agent run respects cancelSignal.
          unawaited(() async {
            try {
              final idx = controller.environmentIndex;
              if (idx == null) return;
              final ok = await idx.refresh(
                  host: envHost,
                  cancelSignal: cancel.future,
                  modelRef: envModelRef,
                  asker: envAsker.ask,
                  scoutSinkFactory: scoutPanelSink);
              if (cancel.isCompleted) {
                initialHost.showMessage('[environment agent cancelled]\n', style: HostMessageStyle.warning);
              } else if (ok) {
                initialHost.showMessage('Environment record updated (.tina/ENVIRONMENT.md).\n', style: HostMessageStyle.success);
              } else {
                initialHost.showMessage(
                    'environment agent did not update .tina/ENVIRONMENT.md — the '
                    'record stays stale, so first load will offer to run it '
                    'again on the next launch (details in the Environment '
                    'panel)\n',
                    style: HostMessageStyle.warning);
              }
            } catch (e) {
              initialHost.showMessage('environment agent failed: $e\n', style: HostMessageStyle.error);
            }
          }());
          return;
        }

        switch (config.environmentAutoPopulate) {
          case EnvironmentAutoPopulate.never:
            return;
          case EnvironmentAutoPopulate.always:
            // "Don't ask" also means no model picker: run on the persisted
            // `[environment] model`, else the shipped default.
            launch(config.environmentModel ?? kDefaultEnvironmentModelRef);
          case EnvironmentAutoPopulate.ask:
            // The explainer renders INSIDE the picker panel (as body text)
            // rather than being posted to the chat, so it scrolls with the
            // picker instead of landing at the bottom of the main panel.
            const explainer = 'No .tina/ENVIRONMENT.md found.\n'
              '\n'
              'Tina uses .tina/ENVIRONMENT.md to build a <project-environment> block for every agent. '
              'It describes how the repo is built, tested and authenticated so agents can run '
              'setup/build/test reliably and avoid guessing.\n'
              '\n'
              'The environment agent is a one-off doing worker that spawns its own side panel agent '
              'so the work does not clutter the main conversation; only start/completion notices '
              'are posted to the main panel. It will:\n'
              '- Spawn one read-only scout per folder (repo root + each top-level subfolder, each in its own side panel), each describing its folder and project type\n'
              '- Inspect dependency manifests and toolchain, e.g. package.json, Cargo.toml, go.mod, pyproject.toml, Gemfile\n'
              '- Run the setup step, then build and run the test suite, recording real pass/fail/skipped counts\n'
              '- Check git identity, SSH keys and GitHub auth, recording references only — no secrets are written to the file\n'
              '- Write .tina/ENVIRONMENT.md with intent sections Toolchain/Setup/Build/Test/Auth you can edit, '
              '  and observed sections Test baseline + verified-at stamp that the agent maintains from measurements\n'
              '\n'
              'It uses the normal sandboxed bash/write/edit tools and will ask for permission for each action. '
              'Esc-Esc cancels. Success is only reported when the file '
              'is created/changed by the agent, not on a prose-only answer.\n';
            final choice = await runListOverlay<String>(
              screen: screen,
              editor: editor,
              entries: const [
                (display: 'Run now in side panel (this session)', value: 'now'),
                (display: 'Always auto-run on first load', value: 'always'),
                (display: 'Not now', value: 'later'),
              ],
              title: 'No ENVIRONMENT.md yet — populate the environment record?',
              footer: '↑↓ move · enter select · esc cancel',
              accent: 'cyan',
              body: explainer,
            );
            if (choice == null || choice == 'later') return;
            if (choice == 'always') {
              // Persist the "don't ask again" answer before launching, so an
              // interrupt mid-run still leaves the preference recorded.
              // Best-effort: a failed write never blocks the launch.
              try {
                final cfg = loadUserConfig(env: app.environment.env);
                writeUserConfig(
                  cfg.copyWith(environmentAutoPopulate: 'always'),
                  env: app.environment.env,
                );
                initialHost.showMessage(
                  'Saved: the environment agent will run automatically on '
                  'first load (`[environment] auto_populate` in '
                  '~/.tina/config)\n',
                  style: HostMessageStyle.dim,
                );
              } catch (_) {}
            }
            launch(await pickEnvironmentModel());
        }
      };
    }

    // .gitignore guard: session transcripts land in `<cwd>/.tina/sessions/`
    // — inside the repo's working tree, where they could be committed. If the
    // repo's .gitignore doesn't cover `.tina` yet (and the user hasn't said
    // "don't ask again" for this repo), offer to add it. Recorded here,
    // performed in [run] after the first paint — the same lifecycle as the
    // first-load environment ask above (the picker needs the editor's key
    // stream). Interactive only; headless runs never create panels.
    final gitRoot = gitRepoRootFor(Directory.current.path);
    final gitignoreAsks = GitignoreAskStore.forTinaDir(
        tinaDirFromEnv(app.environment.env));
    if (gitRoot != null &&
        !gitignoreCoversTinaAt(gitRoot) &&
        !gitignoreAsks.isDeclined(gitRoot)) {
      coordinator.pendingGitignoreAsk = () async {
        final choice = await runListOverlay<String>(
          screen: screen,
          editor: editor,
          entries: const [
            (display: "Add '.tina/' to .gitignore", value: 'add'),
            (display: "Don't ask again for this repo", value: 'never'),
            (display: 'Not now', value: 'later'),
          ],
          title: 'Keep session transcripts out of git?',
          footer: '↑↓ move · enter select · esc skip',
          accent: 'cyan',
          body: 'Tina stores session transcripts in .tina/sessions/ inside '
              'this repo '
              '(${p.relative(gitRoot, from: Directory.current.path)}).\n'
              '\n'
              'The .gitignore at the repo root does not cover .tina yet, so '
              'transcripts could be committed accidentally.',
        );
        switch (choice) {
          case 'add':
            try {
              addTinaToGitignore(File(p.join(gitRoot, '.gitignore')));
              initialHost.showMessage(
                  "Added '.tina/' to ${p.join(gitRoot, '.gitignore')}\n",
                  style: HostMessageStyle.dim);
            } catch (e) {
              initialHost.showMessage(
                  'Could not update .gitignore: $e\n',
                  style: HostMessageStyle.dim);
            }
          case 'never':
            gitignoreAsks.setDeclined(gitRoot, true);
          default:
            break; // 'later' / esc: ask again next launch.
        }
      };
    }
    // Background update check (COCOON_UPDATE_CHECK=0 to disable): cache-first
    // GitHub probe that drops a single dim notice in the chat when a newer
    // release is out. Fire-and-forget like the catalog fetch — a network miss
    // never surfaces. Also sweeps any `<bundle>.old` a previous update left.
    if (app.environment.env['COCOON_UPDATE_CHECK'] != '0') {
      cleanupStaleOldBundle();
      unawaited(() async {
        final checker = ReleaseChecker(env: app.environment.env);
        try {
          final release = await checker.checkCached();
          if (release != null && isNewer(release.tag)) {
            // Let the screen settle first so the notice lands in a painted
            // chat (same reason as the ENVIRONMENT.md notice above).
            await Future<void>.delayed(const Duration(milliseconds: 50));
            initialHost.showMessage(
              'tina ${release.tag} is available — /update to install\n',
              style: HostMessageStyle.dim,
            );
          }
        } finally {
          checker.close();
        }
      }());
    }
    // `/spend`: the process-wide token ledger (all agents + sub-agents +
    // workflows + /index runs), persisted into the session manifest.
    controller.spendLedger = app.spendLedger;
    controller.confirm = (prompt) async {
      final title =
          prompt.replaceFirst(RegExp(r'\s*\[\s*y/N\s*\]\s*$'), '').trim();
      final choice = await runListOverlay<bool>(
        screen: screen,
        editor: editor,
        entries: const [(display: 'Yes', value: true), (display: 'No', value: false)],
        title: title,
        footer: '↑↓ move · enter select · esc cancel',
        accent: 'cyan',
      );
      return choice ?? false;
    };

    return coordinator;
  }

  /// Repaint the session bar from current state. Called on resize (the info
  /// region's bounds change) — the per-change refresh happens inside
  /// [refreshSessionMenu] in [create].
  void _refreshSessionBar() {
    _sessionBar.refresh(
      sessions: sessionManager
          .listSessions()
          .map((s) => (id: s.id, label: s.label, isActive: s.isActive,
                isRunning: s.isRunning, unread: s.unread))
          .toList(),
      hasSidePanels: panelManager.hasSpawnedFrames,
    );
  }

  Future<RunOutcome> run({bool setupMode = false}) async {
    _sigintSub = ProcessSignal.sigint.watch().listen((_) {
      // Delegate to the line editor so it can clear the buffer or confirm quit.
      editor.inject(ControlKey(ControlCode.ctrlC));
    });

    _sigwinchSub = ProcessSignal.sigwinch.watch().listen((_) {
      // Preserve the split/no-split state across resize. The canonical sequence
      // lives in [ResizeCoordinator.handleResize].
      _resizeCoordinator.handleResize(
        split: panelManager.hasSpawnedFrames,
        drawInfoFrame: !panelManager.hasSpawnedFrames,
      );
      // The info region's bounds changed; repaint the session bar into them.
      _refreshSessionBar();
    });

    try {
      // Raw mode so keystrokes reach the editor unbuffered. No-op tolerantly
      // when there's no controlling TTY (e.g. a test harness) — the screen
      // still renders; the REPL simply won't get raw input in that case.
      stdin.echoMode = false;
      stdin.lineMode = false;
    } catch (_) {}

    // Probe terminal background via OSC 11. Use stdio.stdin (which wraps
    // io.stdin in a broadcast relay) so that AnsiInputBackend can also
    // subscribe to stdin after the probe has consumed its first event —
    // otherwise io.stdin's single-subscription stream throws "already
    // listened to". Failures (timeout, parse error) are non-fatal — keep the
    // current theme.
    //
    // Skip for notcurses screens: notcurses opens /dev/tty and runs its own
    // blocking input reader, which would race the probe for the OSC 11
    // response (and consume it). notcurses already resolved the theme via
    // _resolveNcTheme using its default-background API, so the probe is
    // redundant here.
    // Skip the probe when there's no interactive terminal: a non-terminal
    // stdin (piped / test fake) is single-subscription, and the probe's
    // .first would both consume the first event (stealing the REPL's input)
    // and burn the stream so the REPL's input backend can't subscribe
    // ("Stream has already been listened to"). With a terminal there's no
    // input yet at this point, so the probe is safe and worth running.
    if (config.theme == const Theme.defaults() &&
        screen.backend is! NotcursesBackend &&
        screen.io.hasTerminal) {
      final detected = await probeTerminalBg(probeStdin: screen.io.stdin);
      if (detected != TerminalBg.unknown) {
        screen.setTheme(detected == TerminalBg.light
            ? const Theme.light()
            : const Theme.dark());
      }
    }

    screen.enterAltScreen();

    // First paint: assign the primary panel as home, then run the canonical
    // resize sequence so the panels lay out, content relays, and the shared
    // input repoints in the one pinned order. Routing first-paint through
    // [ResizeCoordinator.handleResize] collapses it with the SIGWINCH handler
    // and the three first-spawn blocks into a single path, so the order can
    // never drift between them.
    focusManager.home = panelManager.primaryFrame;
    _resizeCoordinator.handleResize(
      split: panelManager.hasSpawnedFrames,
      drawInfoFrame: !panelManager.hasSpawnedFrames,
    );
    if (_warning != null) {
      await _showFallbackOverlay(screen, _warning);
    }
    _refreshSessionMenu();

    if (setupMode) {
      // First-run setup overlay on top of the (idle) chat. The overlay writes
      // ~/.tina/config on confirm; main() then relaunches with it. On cancel,
      // main() prints a hint and exits. The REPL never starts in setup mode.
      final wrote = await _setupOverlay();
      await _teardownAndHint();
      return wrote != null
          ? RunOutcome.setupWrote
          : RunOutcome.setupCancelled;
    }

    // Replay any loaded conversation history (--continue / --resume) into the
    // chat region. Without this the messages sit in the data model but the
    // screen stays blank until the user types something new.
    final conv = sessionManager.activeConversation;
    if (conv.history.isNotEmpty) {
      replayHistory(conv.host, conv.history);
    }

    // ESC cancels the active conversation's in-flight turn. The controller is
    // UI-agnostic and never touches the editor, so the TUI owns this wiring.
    editor.onEscape = controller.cancelActiveTurn;

    // First-load environment ask (recorded by create): run it now, after the
    // first paint and before the REPL takes the keyboard. Consumed once.
    final firstLoadAsk = pendingFirstLoadEnvironmentAsk;
    if (firstLoadAsk != null) {
      pendingFirstLoadEnvironmentAsk = null;
      await firstLoadAsk();
    }

    // .gitignore ask (recorded by create), same lifecycle as above. Runs
    // after the environment ask so an env-agent launch isn't held up.
    final gitignoreAsk = pendingGitignoreAsk;
    if (gitignoreAsk != null) {
      pendingGitignoreAsk = null;
      await gitignoreAsk();
    }

    try {
      await controller.run();
    } finally {
      await _teardownAndHint();
    }
    return RunOutcome.normal;
  }

  /// The first-load environment-agent ask, recorded by [create] when
  /// `ENVIRONMENT.md` is absent and the project is trusted, and performed by
  /// [run] after the first paint but before the REPL loop starts — the picker
  /// needs the editor's key stream, which the line loop would otherwise
  /// hold. Null (the common case) means no ask is pending. Public so `create`
  /// (a factory) can set it on the instance it is building; tests can clear
  /// it to skip the picker.
  Future<void> Function()? pendingFirstLoadEnvironmentAsk;

  /// The .gitignore ask, recorded by [create] when the cwd is inside a git
  /// repo whose `.gitignore` doesn't cover `.tina` (and the user hasn't
  /// declined for that repo). Same recorded-by-create / performed-by-run
  /// lifecycle as [pendingFirstLoadEnvironmentAsk].
  Future<void> Function()? pendingGitignoreAsk;

  /// Capture exit state, close the store, leave the alt screen, print the resume
  /// hint, and tear down the editor + signal subs. Shared by the normal exit
  /// path and the setup-mode early return.
  Future<void> _teardownAndHint() async {
    final ctx = _captureExitContext();
    await store.close();
    await _teardownUi();
    final hint = resumeHintText(ctx);
    if (hint.isNotEmpty) stdout.writeln(hint);
    _teardownEditor();
  }

  // -- Spawned panel helpers -----------------------------------------------

  /// Snapshot of session state for the exit hint, captured before [closeAll]
  /// clears the live sessions. Reads only in-memory data, so it's safe to call
  /// before [store.close] too.
  ExitContext _captureExitContext() {
    if (!sessionManager.hasActiveSession) {
      return const ExitContext();
    }
    final conv = sessionManager.activeConversation;
    // Report a session ID if something was written this session (lazy init
    // happened) OR if history was loaded from disk (--resume/--continue).
    final recorder = conv.recorder;
    final saved = (recorder != null && recorder.isInitialized) ||
        conv.history.isNotEmpty;
    return ExitContext(
      sessionId: saved ? recorder?.sessionId : null,
      messageCount: conv.history.length,
    );
  }

  /// Phase 1 of teardown: dispose UI widgets, close sessions + sub-agents, restore
  /// terminal modes, and leave the alt screen. After this returns, stdout reaches
  /// the normal scrollback and is safe to write to — so any post-exit output
  /// (e.g. the resume hint) belongs in the seam between this and [_teardownEditor].
  Future<void> _teardownUi() async {
    editor.disposeInput();
    menuBar.dispose();
    _sessionBar.hide();
    progressSub.cancel();
    pauseSub.cancel();
    panelManager.dispose();
    _contentCoordinator.dispose();
    sessionManager.closeAll();
    await subAgentScheduler.dispose();
    subAgentScheduler.registry.catalog?.close();
    try {
      stdin.echoMode = true;
      stdin.lineMode = true;
    } catch (_) {}
    screen.leaveAltScreen();
    // Terminal is restored; a later crash no longer needs the screen ref.
    _guardedScreen = null;
  }

  void _teardownEditor() {
    editor.close();
    _sigintSub?.cancel();
    _sigwinchSub?.cancel();
  }
}

/// Snapshot of session state captured just before teardown, so the resume hint
/// can report the session id + size after [SessionManager.closeAll] has cleared
/// the live sessions. Plain data — no references to objects that get torn down.
class ExitContext {
  /// The persisted session id to show with `--resume`, or null/empty when
  /// nothing was written to disk (empty session).
  final String? sessionId;

  /// Messages in the active conversation at exit (null only when there was no
  /// active session).
  final int? messageCount;

  const ExitContext({this.sessionId, this.messageCount});
}

/// The resume hint printed after the alt screen is left on exit. Pure (no I/O)
/// so it's unit-testable in isolation; [TuiCoordinator.run] writes the result to
/// stdout in the teardown seam. Returns the empty string when there's nothing to
/// show (empty session, nothing on disk).
String resumeHintText(ExitContext ctx) {
  final id = ctx.sessionId;
  if (id == null || id.isEmpty) return '';
  final count = ctx.messageCount;
  final suffix = count == null ? '' : ' ($count messages)';
  return 'session saved: $id$suffix\n'
      'resume: tina --resume $id\n'
      '        tina -c';
}

/// notcurses was explicitly requested (`--backend notcurses`) but couldn't be
/// initialized. notcurses is a hard requirement in that mode — we never fall
/// back to ANSI silently — so this surfaces as a clean one-line error (caught
/// in `main`) instead of a raw initializer stack trace.
class BackendUnavailableError implements Exception {
  final String message;
  BackendUnavailableError(this.message);
  @override
  String toString() => message;
}

/// The live [Screen], tracked for [emergencyTerminalRestore]. The crash path
/// (a zone-level unhandled error, a signal) has no other way to reach the
/// backend that owns the terminal — and notcurses stop() is the only thing
/// that restores the exact termios it captured at init. Set in
/// [_createScreen] the moment the backend may own the tty; cleared in
/// [_teardownUi] once the screen has been torn down normally.
Screen? _guardedScreen;

/// Restore the terminal after an unexpected exit: an unhandled error caught by
/// the entrypoint's zone guard, or SIGTERM/SIGHUP mid-TUI.
///
/// The TUI flips the tty into raw mode (echo/line mode off, plus notcurses'
/// own termios), and a crash path that skips [_teardownUi] would leave it that
/// way — a dead shell where backspace prints junk and ^C is a literal byte.
/// This stops the live backend (notcurses restores its saved termios + leaves
/// the alt screen), then force-restores the mode flags (the ANSI backend
/// touches nothing but stdio flags, so this is what resets it there).
/// Idempotent and safe to call at any point.
void emergencyTerminalRestore() {
  final screen = _guardedScreen;
  if (screen != null) {
    try {
      screen.leaveAltScreen(); // no-op when never entered / already stopped
    } catch (_) {}
  }
  try {
    stdin.echoMode = true;
  } catch (_) {}
  try {
    stdin.lineMode = true;
  } catch (_) {}
  // Exit the alt screen + reset SGR when no backend was live (crash before
  // the TUI took over). Harmless no-op on a healthy terminal.
  stdout.write('\x1b[?1049l\x1b[0m');
}

/// Build a [Screen] per the configured backend ([Config.backend]).
///
/// Returns a record of (screen, warning?).
/// - `ansi`: force the ANSI backend.
/// - `notcurses`: force notcurses. If it can't initialize, throw
///   [BackendUnavailableError] — never fall back silently.
({Screen screen, String? warning}) _createScreen(
  Config config,
  Stdio io,
  ScreenLayout layout,
) {
  switch (config.backend) {
    case BackendChoice.ansi:
      final screen = Screen(io: io, layout: layout, theme: config.theme);
      _guardedScreen = screen;
      return (screen: screen, warning: null);

    case BackendChoice.notcurses:
      // Explicit selection — never fall back to ANSI. If notcurses can't
      // initialize (library missing, no controlling TTY, etc.), surface a
      // clean error and quit nonzero rather than silently downgrading. The
      // shared-library probe is intentionally skipped here: with vendored
      // static linking it false-negatives, so the real test is whether
      // create() succeeds.
      try {
        final nc = NotcursesBackend.create(io: io, mouseWheel: config.mouseWheel);
        try {
          final effTheme = _resolveNcTheme(nc, config.theme);
          final screen = Screen.withBackend(
              backend: nc, io: io, layout: layout, theme: effTheme);
          _guardedScreen = screen;
          return (screen: screen, warning: null);
        } catch (_) {
          // create() already put the tty in raw mode + alt screen, but the
          // backend's _inAltScreen flag is false until enterAltScreen tracks
          // it — mark it so leaveAltScreen() runs the platform stop() that
          // restores the terminal before the failure propagates.
          try {
            nc.enterAltScreen();
            nc.leaveAltScreen();
          } catch (_) {}
          rethrow;
        }
      } catch (e) {
        throw BackendUnavailableError(
            '--backend notcurses: notcurses could not initialize\n  $e');
      }
  }
}

/// When the user hasn't explicitly configured a theme, use the notcurses
/// default-background API to pick a matching light/dark scheme.
Theme _resolveNcTheme(NotcursesBackend nc, Theme configTheme) {
  // Only auto-detect when the config theme is at its shipped defaults.
  if (configTheme != const Theme.defaults()) return configTheme;
  final bg = nc.defaultBackground;
  if (bg == null) {
    return bgFromPlatform() == TerminalBg.light
        ? const Theme.light()
        : const Theme.dark();
  }
  final r = (bg >> 16) & 0xFF;
  final g = (bg >> 8) & 0xFF;
  final b = bg & 0xFF;
  return bgFromRgb(r, g, b) == TerminalBg.light
      ? const Theme.light()
      : const Theme.dark();
}

/// Show a modal overlay on [screen] with [message], then wait for any
/// keypress to dismiss.
Future<void> _showFallbackOverlay(Screen screen, String message) async {
  final lines = message.split('\n');
  final maxW = lines.fold(0, (m, l) => l.length > m ? l.length : m);
  final boxW = maxW + 4;
  final boxH = lines.length + 2;
  final row = (screen.layout.height - boxH) ~/ 2;
  final col = (screen.layout.width - boxW) ~/ 2;
  final rect = Rect(row: row, col: col, width: boxW, height: boxH);
  final overlay = OverlayRegion(screen, rect);

  final boxed = <String>[];
  for (final line in lines) {
    final padded = line.padRight(maxW);
    boxed.add(' $padded ');
  }
  overlay.show(boxed);

  // Wait for any keypress.
  await stdin.first;
  overlay.hide();
  overlay.dispose();
}
