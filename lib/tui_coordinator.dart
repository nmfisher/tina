import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'package:tina/completion/git_file_provider.dart';
import 'package:tina/completion/command_completion_provider.dart';
import 'package:tina/composition/agent_composition.dart';
import 'package:tina/composition/app_composition.dart';
import 'package:tina/config.dart';
import 'package:tina/config/spawn_mru.dart';
import 'package:tina/config/user_config.dart';
import 'package:tina/host/tui_conversation_host.dart';
import 'package:tina/persistence/session_restore.dart';
import 'package:tina/platform/terminal_geometry.dart';
import 'package:tina/session_controller.dart';
import 'package:tina/summaries/summary_index.dart';
import 'package:tina/conversation.dart';
import 'package:tina/session_manager.dart';
import 'package:tina/tui/spawn_overlay.dart';
import 'package:tina/tui/tree_order.dart';
import 'package:tina/tui/panel_manager.dart';
import 'package:tina/tui/conversation_panel_coordinator.dart';
import 'package:tina/tui/resize_coordinator.dart';
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
  })  : _warning = warning,
        _refreshSessionMenu = refreshSessionMenu,
        _setupOverlay = setupOverlay,
        _tree = tree,
        _contentCoordinator = contentCoordinator,
        _resizeCoordinator = resizeCoordinator;

  static Future<TuiCoordinator> create({
    required AppComposition app,
    Stdio? io,
    TerminalGeometry? terminalGeometry,
    Future<UserConfig?> Function()? setupOverlay,
    // Injectable model+role picker shared by `/spawn` and `/branch`. The real
    // pickers drive terminal overlays (runSpawnOverlay → runRoleOverlay) which
    // need a live terminal and so can't run under test. When omitted, the
    // closures capture the in-scope [pickSpawnedTarget] helper; tests pass a
    // canned (ref, role) to drive the live fork body without the overlays.
    Future<({String ref, AgentRole role})?> Function()? spawnTargetPicker,
  }) async {
    final config = app.config;
    final reg = app.registry;
    final provider = app.provider;
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

    // Constructs the per-conversation terminal host. A background conversation
    // gets a fresh, detached chat region (so its output buffers until it is
    // switched to) and a no-op spinner; [TuiConversationHost.setActive] routes
    // it onto the screen and binds its spinner to the status row on switch.
    // The shared [editor] lets an active conversation read a permission
    // keystroke. isActive is true only for the initial conversation.
    HostInterface hostFactory({
      required String conversationId,
      required bool isActive,
    }) =>
        TuiConversationHost(
          conversationId: conversationId,
          chat: ScrollingTextRegion(screen)..detach(),
          spinner: Spinner(enabled: false),
          screen: screen,
          editor: editor,
          active: isActive,
        );

    // Tools, the sub-agent catalog, the scheduler, and the per-conversation
    // Agent builder live in agent_composition.dart — app-level composition
    // shared with the headless path. The initial Agent and every later
    // session's Agent are built by buildAgent(); the SessionManager reuses it
    // as its agentBuilder.

    // Build the initial session. Its host adopts screen.chat as its (active)
    // region and the shared spinner (bound to the status row), so it is on
    // screen from construction — active: true gives it an interactive asker.
    final initialSessionId = app.initialSessionId;
    final initialConversationId = app.initialConversationId;
    final initialHistory = app.initialHistory;
    // Resolve the main role's system prompt ONCE so the recorder's captured
    // metadata and the agent's actual prompt can't drift (and aren't compiled
    // twice). Stored in the conversation meta so resume replays the exact prompt.
    final initialSystem = resolveSystemPrompt(pipeline.mainRole,
        overrides: config.promptOverrides,
        safeMode: config.safeMode,
        loadProjectContext: pipeline.loadProjectContext);
    final initialRecorder = SessionRecorder(
        store, initialSessionId, initialConversationId,
        providerId: config.provider,
        baseUrl: config.baseUrl,
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
    final initialAgent = buildAgent(
      pipeline: pipeline,
      scheduler: scheduler,
      conversationId: initialConversationId,
      provider: provider,
      host: initialHost,
      policy: policy,
      config: config,
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
        accountProvider: provider,
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
              role: meta.targetName ?? pipeline.mainRole.name,
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
    }

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
      label: panelLabel(
          role: pipeline.mainRole.name, model: provider.model),
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
          pipeline: pipeline,
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

    // The shared `/spawn` + `/branch` flow: model-picker then role-picker. Both
    // commands present the identical overlay sequence (per the "same as spawn"
    // requirement on `/branch`); they only diverge once a target is chosen.
    // Returns the chosen (modelRef, role) or null if either overlay is
    // cancelled — the caller treats null as "no action".
    Future<({String ref, AgentRole role})?> pickSpawnedTarget() async {
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

      // Pick the agent's role — its prompt identity + tool set. Cancel here
      // aborts the spawn (the model was chosen but no agent yet).
      final role = await runRoleOverlay(
        screen: screen,
        editor: editor,
        roles: defaultPipeline.roles,
      );
      if (role == null) return null;
      return (ref: selected, role: role);
    }

    // Resolve the model+role picker once: an injected [spawnTargetPicker]
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
      final role = pick.role;

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

      // Derive the agent from the chosen role: its tool set and prompt identity
      // (honoring any [prompts.<role>] override), and a policy that allows
      // exactly those tools so the side panel never prompts for them.
      // --safe-mode: drop write/edit/bash from the spawned side panel too, and
      // tell it the tree is read-only.
      final eff = config.safeMode ? stripForSafeMode(role.tools) : role.tools.toList();
      final spawnSystem = resolveSystemPrompt(role,
          overrides: cfg.prompts,
          safeMode: config.safeMode,
          loadProjectContext: pipeline.loadProjectContext);
      final roleToolNames = eff.map((t) => t.schema.name).toList();
      final spawnTools = ToolRegistry(eff);
      final spawnPolicy = PermissionPolicy(rules: [
        for (final n in roleToolNames)
          PermissionRule(
              toolName: n, pattern: '*', decision: PermissionDecision.allow),
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
          targetName: role.name,
          parentConversationId: sessionManager.activeConversationId,
        ),
      );
      // Record the tree edge so the layout can nest this panel under its parent
      // (the focused conversation at spawn time) and indent it by depth.
      tree.parentOf[chatId] = sessionManager.activeConversationId;
      tree.baseLabel[chatId] = panelLabel(role: role.name, model: selected);
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
        maxSteps: role.maxSteps ?? 50,
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
        label: '${role.name} (${selected})',
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
          host: host, label: panelLabel(role: role.name, model: selected));

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
      final role = pick.role;

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

      // Derive the agent from the chosen role (mirrors /spawn).
      final eff = config.safeMode ? stripForSafeMode(role.tools) : role.tools.toList();
      final branchSystem = resolveSystemPrompt(role,
          overrides: cfg.prompts,
          safeMode: config.safeMode,
          loadProjectContext: pipeline.loadProjectContext);
      final roleToolNames = eff.map((t) => t.schema.name).toList();
      final branchTools = ToolRegistry(eff);
      final branchPolicy = PermissionPolicy(rules: [
        for (final n in roleToolNames)
          PermissionRule(
              toolName: n, pattern: '*', decision: PermissionDecision.allow),
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
        targetName: role.name,
        parentConversationId: sessionManager.activeConversationId,
      );
      final chatId =
          await store.createConversationWithMeta(branchSessionId, branchMeta);
      tree.parentOf[chatId] = sessionManager.activeConversationId;
      tree.baseLabel[chatId] = panelLabel(role: role.name, model: selected);

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
        label: panelLabel(role: role.name, model: selected),
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
        label: '${role.name} (${selected})',
        agent: Agent(
          provider: branchProvider,
          tools: branchTools,
          sink: host,
          policy: branchPolicy,
          asker: host.askPermission,
          system: branchSystem,
          pauseGate: scheduler.pauseGate,
          maxSteps: role.maxSteps ?? 50,
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
      for (final pid in scheduler.registry.providerIds) {
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
          : pipeline.mainRole.name;
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
    );

    // `/index`: the per-directory summary sidecar. The service holds the live
    // composition's config/registry/environment (the recipe, safe to share) so
    // it can both probe staleness (pure git, no LLM) and run the summarizer
    // fleet. The y/n confirm reads a single key via the shared line editor —
    // the same primitive the permission modal uses.
    controller.summaryIndex = SummaryIndex(
      config: app.config,
      registry: app.registry,
      environment: app.environment,
      projectRoot: Directory.current.path,
    );
    controller.confirm = (prompt) async {
      final host = sessionManager.activeConversation.host;
      host.showMessage(prompt);
      final event = await editor.readKey();
      final yes = event is CharInput && event.text.toLowerCase() == 'y';
      host.showMessage('${event is CharInput ? event.text : ''}\n');
      return yes;
    };

    return coordinator;
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
      await _showFallbackOverlay(screen, _warning!);
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

    try {
      await controller.run();
    } finally {
      await _teardownAndHint();
    }
    return RunOutcome.normal;
  }

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
      return (
        screen: Screen(io: io, layout: layout, theme: config.theme),
        warning: null,
      );

    case BackendChoice.notcurses:
      // Explicit selection — never fall back to ANSI. If notcurses can't
      // initialize (library missing, no controlling TTY, etc.), surface a
      // clean error and quit nonzero rather than silently downgrading. The
      // shared-library probe is intentionally skipped here: with vendored
      // static linking it false-negatives, so the real test is whether
      // create() succeeds.
      try {
        final nc = NotcursesBackend.create(io: io);
        final effTheme = _resolveNcTheme(nc, config.theme);
        return (
          screen: Screen.withBackend(
              backend: nc, io: io, layout: layout, theme: effTheme),
          warning: null,
        );
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
