import 'dart:async';
import 'dart:io';
import 'package:tina_app/tina_app.dart';
import 'package:tina/config.dart';
import 'package:tina/config/user_config.dart';
import 'package:tina/pipeline/workflow_permission_asker.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina/tui_coordinator.dart';
import 'package:test/test.dart';

import 'helpers/fake_environment.dart';
import 'helpers/fake_provider.dart';
import 'helpers/fake_stdio.dart';
import 'helpers/fake_terminal_geometry.dart';
import 'helpers/memory_session_store.dart';

/// Integration tests for [TuiCoordinator].
void main() {
  test(
    'failed side-panel presentation retains the registered conversation',
    () async {
      final temp = Directory.systemTemp.createTempSync('tina-present-failure-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final registry = ProviderRegistry(env: const {})
        ..register(
          ProviderDescriptor(
            id: 'test',
            name: 'Test',
            authSources: const [],
            defaultBaseUrl: 'https://example.test',
            builder: (_) => FakeProvider.done(),
          ),
        );
      final config = Config.parse(
        ['--model', 'test/model', '--backend', 'ansi'],
        env: const {},
        registry: registry,
      );
      final store = MemorySessionStore();
      final app = await buildAppComposition(
        config: config,
        registry: registry,
        provider: FakeProvider.done(),
        store: store,
        environment: FakeEnvironment(env: {'HOME': temp.path}),
      );
      final io = FakeStdio()..hasTerminalValue = false;
      final coordinator = await TuiCoordinator.create(
        app: app,
        io: io,
        terminalGeometry: const FakeTerminalGeometry(columns: 120, lines: 24),
        spawnTargetPicker: () async =>
            (ref: 'test/model', profile: ToolProfile.readOnly),
        sideConversationPresenter: (_) => throw StateError('attachment failed'),
      );
      coordinator.pendingFirstLoadEnvironmentAsk = null;
      await coordinator.controller.openSpawn!();
      expect(coordinator.sessionManager.active.conversationCount, 2);
      final side = coordinator.sessionManager.active.conversations.last;
      expect(
        (await store.loadSession(side.recorder!.sessionId)).conversations,
        hasLength(2),
      );
      final manifest = await store.loadSession(side.recorder!.sessionId);
      expect(
        store.metaFor(side.recorder!.sessionId, side.id)!.parentConversationId,
        manifest.activeConversationId,
        reason: 'fresh primary persistence may remint its in-memory id',
      );
      expect(coordinator.spawnedPanels, isEmpty);
      expect(
        io.written.toString(),
        contains('was saved, but its panel could not be attached'),
      );
      io.feedBytes('/exit\r\r'.codeUnits);
      await coordinator.run().timeout(const Duration(seconds: 5));
    },
  );

  group('resumeHintText', () {
    test('prints the session id, message count, and both resume commands', () {
      final text = resumeHintText(
        const ExitContext(sessionId: '20260703-143012-a1b2', messageCount: 42),
      );
      expect(
        text,
        contains('session saved: 20260703-143012-a1b2 (42 messages)'),
      );
      expect(text, contains('resume: tina --resume 20260703-143012-a1b2'));
      expect(text, contains('        tina -c'));
    });

    test('omits the count suffix when messageCount is null', () {
      final text = resumeHintText(const ExitContext(sessionId: 'sid'));
      expect(text, contains('session saved: sid'));
      expect(text, isNot(contains('messages')));
    });

    test('is silent when there is no session id', () {
      expect(resumeHintText(const ExitContext()), '');
    });

    test('appends the tmux attach line when one is supplied (tin-f5xt)', () {
      // Inside tmux the process dies on exit, so the hint must teach the
      // reattach command instead of pretending --resume revives the agent.
      final text = resumeHintText(
        const ExitContext(sessionId: '20260703-143012-a1b2'),
        tmuxAttach: 'tmux attach -t tin-20260703-143012-a1b2',
      );
      expect(text, contains('tina -c'));
      expect(
        text,
        contains('\n        tmux attach -t tin-20260703-143012-a1b2'),
      );
      // It's an addition, not a replacement — the plain resume commands stay.
      expect(text, contains('resume: tina --resume 20260703-143012-a1b2'));
    });

    test('stays unchanged outside tmux (no attach line)', () {
      final text = resumeHintText(
        const ExitContext(sessionId: 'sid', messageCount: 1),
      );
      expect(text, isNot(contains('tmux attach')));
      expect(text, endsWith('        tina -c'));
    });
  });

  test(
    'quit confirmation is disposed before leaving the alternate screen',
    () async {
      final io = FakeStdio()..hasTerminalValue = false;
      final config = Config.parse(const ['--backend', 'ansi']);
      final app = await buildAppComposition(
        config: config,
        registry: builtinRegistry(),
        provider: FakeProvider.done(),
        store: MemorySessionStore(),
      );
      final coordinator = await TuiCoordinator.create(
        app: app,
        io: io,
        terminalGeometry: const FakeTerminalGeometry(columns: 80, lines: 24),
      );
      coordinator.pendingFirstLoadEnvironmentAsk = null;
      coordinator.pendingGitignoreAsk = null;
      // Ctrl-C opens the confirmation; the second quits with it still visible.
      io.feedBytes([0x03, 0x03]);
      await coordinator.run().timeout(const Duration(seconds: 5));
      io.close();

      final out = io.written.toString();
      expect(out, contains('Ctrl+C again to exit'));
      const leave = '\x1b[?1049l';
      final leaveAt = out.indexOf(leave);
      expect(leaveAt, greaterThanOrEqualTo(0));
      expect(
        out.substring(leaveAt + leave.length),
        isEmpty,
        reason: 'editor cleanup must not paint after the backend is stopped',
      );
    },
  );

  test('first paint follows the alt-screen-enter escape', () async {
    // Regression guard for the startup first-paint ordering. The first paint
    // (the chat frame) must happen AFTER screen.enterAltScreen(): enterAltScreen
    // redraws the frame, so anything painted before it is erased and the screen
    // is blank on startup until something forces a repaint.
    //
    // We drive the real create() + run() against a fake stdio, feed /exit so
    // the REPL returns, then assert on the captured byte stream: the
    // alt-screen-enter escape must precede the first frame border.
    final io = FakeStdio()..hasTerminalValue = false;
    final config = Config.parse(const ['--backend', 'ansi']);

    final app = await buildAppComposition(
      config: config,
      registry: builtinRegistry(),
      provider: FakeProvider.done(),
      store: MemorySessionStore(),
    );
    final coordinator = await TuiCoordinator.create(
      app: app,
      io: io,
      terminalGeometry: const FakeTerminalGeometry(columns: 80, lines: 24),
    );
    // This test drives the raw first-paint sequence; skip the first-load
    // environment ask (this repo has no ENVIRONMENT.md, so run() would show
    // the picker before the REPL). The ask has its own test below.
    coordinator.pendingFirstLoadEnvironmentAsk = null;

    io.feedBytes([
      0x2f,
      0x65,
      0x78,
      0x69,
      0x74,
      0x0d,
      0x0d,
    ]); // /exit: Enter accepts, Enter submits

    await coordinator.run().timeout(const Duration(seconds: 5));
    io.close();

    final out = io.written.toString();
    final altScreen = out.indexOf('\x1b[?1049h');
    final frameBorder = out.indexOf('┌');
    expect(
      altScreen,
      greaterThanOrEqualTo(0),
      reason: 'should enter alt screen',
    );
    expect(
      frameBorder,
      greaterThanOrEqualTo(0),
      reason: 'chat frame should paint',
    );
    expect(
      altScreen,
      lessThan(frameBorder),
      reason:
          'frame must paint after entering the alt screen; painting '
          'beforehand leaves the borders erased by the frame redraw and the '
          'screen blank on startup',
    );
  });

  test(
    'resume builds the active provider under the current config base',
    () async {
      // Regression (owner bug, 2026-08-24): on resume the TUI replayed the
      // baseUrl CAPTURED in the conversation meta when the session was created,
      // so a stale experimental base-url kept 404-ing forever — no matter what
      // ~/.tina/config said now — for the life of that session. The provider
      // must resolve through buildStartupProvider: the CURRENT config base,
      // applied only under the ref's provider, never the captured one.
      final bases = <String>[];
      final registry = ProviderRegistry(env: const {'TEST_KEY': 'k'})
        ..register(
          ProviderDescriptor(
            id: 'anthropic',
            name: 'anthropic',
            authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
            defaultBaseUrl: 'https://anthropic.test',
            builder: (c) {
              bases.add(c.baseUrl);
              return FakeProvider(const [], model: c.model);
            },
            models: {
              'claude-sonnet-4-6': ModelInfo(
                id: 'claude-sonnet-4-6',
                name: 'S',
                contextWindow: 1,
                maxOutput: 1,
              ),
            },
          ),
        );

      // A session created while a wrong experimental base was configured: the
      // meta froze it, and the transcript exists so --resume resolves it.
      final store = MemorySessionStore();
      final sid = await store.createSession(providerId: 'anthropic');
      final cid = await store.createConversationWithMeta(
        sid,
        ConversationMetaInput.primary(
          providerId: 'anthropic',
          provider: FakeProvider(const [], model: 'claude-3-opus-20240229'),
          baseUrl: 'https://stale.example/v1',
          policy: PermissionPolicy(),
        ),
      );
      await store.append(
        sid,
        cid,
        const Message(role: Role.user, content: [TextBlock('q')]),
      );
      await store.setActiveConversation(sid, cid);

      final io = FakeStdio()..hasTerminalValue = false;
      final config = Config.parse(
        [
          '--resume',
          sid,
          '--backend',
          'ansi',
          '--base-url',
          'https://fresh.example',
        ],
        registry: registry,
        env: const {'TEST_KEY': 'k'},
      );
      final app = await buildAppComposition(
        config: config,
        registry: registry,
        store: store,
        // Timing-sensitive full-loop test: keep the update-check banner (a real
        // network probe) out of the chat stream.
        environment: FakeEnvironment(
          env: {for (final e in Platform.environment.entries) e.key: e.value}
            ..['COCOON_UPDATE_CHECK'] = '0',
        ),
      );
      final coordinator = await TuiCoordinator.create(
        app: app,
        io: io,
        terminalGeometry: const FakeTerminalGeometry(columns: 80, lines: 24),
      );
      coordinator.pendingFirstLoadEnvironmentAsk = null;

      // The ACTIVE conversation's provider was built at create() — under the
      // current config base (and still under the /model-swapped model the meta
      // remembers), never under the captured one.
      expect(
        bases,
        isNot(contains('https://stale.example/v1')),
        reason: 'the base captured at creation must never reach a provider',
      );
      expect(bases.last, 'https://fresh.example');
      expect(
        coordinator.sessionManager.activeConversation.provider.model,
        'claude-3-opus-20240229',
        reason: 'a /model swap during the session still survives resume',
      );

      io.feedBytes([0x2f, 0x65, 0x78, 0x69, 0x74, 0x0d, 0x0d]); // /exit
      await coordinator.run().timeout(const Duration(seconds: 5));
      io.close();
    },
  );

  test(
    'emergencyTerminalRestore leaves the alt screen via the live backend',
    () async {
      // Regression guard for the crash-path terminal restore: when an unhandled
      // error kills tina mid-TUI, the entrypoint's zone guard calls
      // emergencyTerminalRestore() — it must tear down the tracked screen (here
      // the fake io's ANSI backend) so the shell isn't left raw. The screen is
      // tracked from create() onward, so restore works before run() too.
      final io = FakeStdio()..hasTerminalValue = false;
      final config = Config.parse(const ['--backend', 'ansi']);
      final app = await buildAppComposition(
        config: config,
        registry: builtinRegistry(),
        provider: FakeProvider.done(),
        store: MemorySessionStore(),
      );
      final coordinator = await TuiCoordinator.create(
        app: app,
        io: io,
        terminalGeometry: const FakeTerminalGeometry(columns: 80, lines: 24),
      );

      coordinator.screen.enterAltScreen();
      emergencyTerminalRestore(); // must not throw

      final out = io.written.toString();
      expect(
        out,
        contains('\x1b[?1049l'),
        reason: 'crash path must emit the leave-alt-screen escape',
      );
    },
  );

  test(
    'setup mode: overlay writes → setupWrote and the REPL is skipped',
    () async {
      final io = FakeStdio()..hasTerminalValue = false;
      final config = Config.parse(const ['--backend', 'ansi']);
      final app = await buildAppComposition(
        config: config,
        registry: builtinRegistry(),
        provider: FakeProvider.done(),
        store: MemorySessionStore(),
      );
      final coordinator = await TuiCoordinator.create(
        app: app,
        io: io,
        terminalGeometry: const FakeTerminalGeometry(columns: 80, lines: 24),
        // Fake overlay: "collects + writes" a config without touching the screen.
        setupOverlay: () async =>
            const UserConfig(defaultProvider: 'anthropic'),
      );

      final outcome = await coordinator
          .run(setupMode: true)
          .timeout(const Duration(seconds: 5));
      expect(outcome, RunOutcome.setupWrote);
      // The setup branch returns RunOutcome.setupWrote before controller.run()
      // (the REPL) is ever called, and no input was fed (readLine would block
      // otherwise) — so run() returning at all proves the REPL was skipped.
    },
  );

  test('setup mode: overlay cancelled → setupCancelled', () async {
    final io = FakeStdio()..hasTerminalValue = false;
    final config = Config.parse(const ['--backend', 'ansi']);
    final app = await buildAppComposition(
      config: config,
      registry: builtinRegistry(),
      provider: FakeProvider.done(),
      store: MemorySessionStore(),
    );
    final coordinator = await TuiCoordinator.create(
      app: app,
      io: io,
      terminalGeometry: const FakeTerminalGeometry(columns: 80, lines: 24),
      setupOverlay: () async => null, // cancelled
    );

    final outcome = await coordinator
        .run(setupMode: true)
        .timeout(const Duration(seconds: 5));
    expect(outcome, RunOutcome.setupCancelled);
  });

  test(
    '--continue renders the loaded conversation history into the chat',
    () async {
      // Pre-populate a session store with a user message and an agent response.
      final store = MemorySessionStore();
      final sid = await store.createSession(providerId: 'anthropic');
      final cid = await store.createConversation(sid);
      await store.append(
        sid,
        cid,
        Message(role: Role.user, content: [TextBlock('hello agent')]),
      );
      await store.append(
        sid,
        cid,
        Message(role: Role.assistant, content: [TextBlock('hi human')]),
      );

      // --continue loads the most recent session's history.
      final io = FakeStdio()..hasTerminalValue = false;
      final config = Config.parse(const ['--continue', '--backend', 'ansi']);
      final app = await buildAppComposition(
        config: config,
        registry: builtinRegistry(),
        provider: FakeProvider.done(),
        store: store,
      );
      final coordinator = await TuiCoordinator.create(
        app: app,
        io: io,
        terminalGeometry: const FakeTerminalGeometry(columns: 80, lines: 24),
      );
      // Skip the first-load environment ask (see its dedicated test below) —
      // this test drives the history replay, not the startup picker.
      coordinator.pendingFirstLoadEnvironmentAsk = null;

      io.feedBytes([0x2f, 0x65, 0x78, 0x69, 0x74, 0x0d, 0x0d]); // /exit

      await coordinator.run().timeout(const Duration(seconds: 5));
      io.close();

      final out = io.written.toString();
      // The user's message should be rendered in the chat region.
      expect(
        out,
        contains('hello agent'),
        reason: 'the loaded user message must be rendered on startup',
      );
      // The agent's response should also be rendered.
      expect(
        out,
        contains('hi human'),
        reason: 'the loaded agent response must be rendered on startup',
      );
    },
  );

  // The first-load ask's gate reads the process cwd's ENVIRONMENT.md — the
  // repo root is NOT a fixture (the ceremony can legitimately write one
  // during real use, and did), so these tests point the cwd at a fresh temp
  // project for their duration.
  void chdirToFreshProject() {
    final dir = Directory.systemTemp.createTempSync('tina-first-load-');
    final old = Directory.current;
    Directory.current = dir;
    addTearDown(() {
      Directory.current = old;
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
  }

  for (final choice in ['now', 'later', 'always', 'never']) {
    test(
      'first load environment setup: $choice uses the normal main turn',
      () async {
        chdirToFreshProject();
        final io = FakeStdio()..hasTerminalValue = false;
        final provider = FakeProvider.done();
        final config = Config.parse(
          const ['--backend', 'ansi'],
          userConfig: UserConfig(
            environmentAutoPopulate: choice == 'always' || choice == 'never'
                ? choice
                : 'ask',
          ),
        );
        final store = MemorySessionStore();
        final app = await buildAppComposition(
          config: config,
          registry: builtinRegistry(),
          provider: provider,
          store: store,
          environment: FakeEnvironment(
            env: Map.of(Platform.environment)..['COCOON_UPDATE_CHECK'] = '0',
          ),
        );
        final coordinator = await TuiCoordinator.create(
          app: app,
          io: io,
          terminalGeometry: const FakeTerminalGeometry(columns: 120, lines: 40),
        );
        coordinator.pendingGitignoreAsk = null;
        expect(coordinator.pendingFirstLoadEnvironmentAsk, isNotNull);
        final run = coordinator.run();
        if (choice == 'now' || choice == 'later') {
          await pumpEventQueue();
          expect(coordinator.editor.isReadingKey, isTrue);
          expect(provider.calls, isEmpty);
          if (choice == 'later') {
            io.feedBytes([0x1b, 0x5b, 0x42, 0x1b, 0x5b, 0x42]); // Not now
            await pumpEventQueue();
          }
          io.feedBytes([0x0d]);
        }
        await pumpEventQueue(times: 100);
        final main = coordinator.sessionManager.activeConversation;
        await coordinator.controller.turns.whenIdle(main.id);
        final runs = choice == 'now' || choice == 'always';
        expect(provider.calls.length, runs ? 1 : 0);
        expect(coordinator.spawnedPanels, isEmpty);
        expect(coordinator.sessionManager.active.conversationCount, 1);
        if (runs) {
          expect(
            main.history.first.content.whereType<TextBlock>().single.text,
            contains('how many sub-agents to spawn'),
          );
          expect(main.recorder, isNotNull);
        }
        io.feedBytes([0x03, 0x03]);
        await run.timeout(const Duration(seconds: 5));
        io.close();
      },
    );
  }

  test('environment setup spawns exactly the children the main agent delegates', () async {
    chdirToFreshProject();
    final children = <FakeProvider>[];
    final registry = ProviderRegistry(env: const {})..register(ProviderDescriptor(
      id: 'test', name: 'Test', authSources: const [],
      defaultBaseUrl: 'https://example.test',
      builder: (options) {
        final provider = FakeProvider.done(model: options.model);
        children.add(provider);
        return provider;
      },
    ));
    final provider = FakeProvider([
      [MessageComplete(content: [ToolUseBlock(id: 'delegate-env', name: 'delegate', input: {
        'delegations': [
          {'task': 'Inspect the toolchain'},
          {'task': 'Identify test commands'},
        ],
      })], stopReason: 'tool_use')],
      [MessageComplete(content: [TextBlock('Inspection finished; setup still needed.')],
        stopReason: 'end_turn')],
    ], model: 'main-model');
    final config = Config.parse(['--model', 'test/main-model', '--backend', 'ansi'],
      env: const {}, registry: registry);
    final app = await buildAppComposition(config: config, registry: registry,
      provider: provider, store: MemorySessionStore(),
      environment: FakeEnvironment(env: const {'COCOON_UPDATE_CHECK': '0'}));
    final coordinator = await TuiCoordinator.create(app: app,
      io: FakeStdio()..hasTerminalValue = false,
      terminalGeometry: const FakeTerminalGeometry(columns: 120, lines: 40));
    final main = coordinator.sessionManager.activeConversation;
    expect(coordinator.spawnedPanels, isEmpty);
    // Composition may build an idle classifier provider. Only work launched
    // by this task counts toward its delegation choices.
    expect(children.every((child) => child.calls.isEmpty), isTrue);
    children.clear();
    await coordinator.controller.runEnvironment(main);
    await coordinator.controller.turns.whenIdle(main.id);
    expect(provider.calls, hasLength(2));
    expect(children, hasLength(2));
    expect(coordinator.spawnedPanels, hasLength(2));
    expect(coordinator.sessionManager.active.conversationCount, 3);
    expect(coordinator.panelManager.sidebar!.entries.map((e) => e.depth), [0, 1, 1]);
    expect(coordinator.panelManager.selectedFrame, same(coordinator.panelManager.primaryFrame));
    expect(main.history.expand((m) => m.content).whereType<ToolResultBlock>(), isNotEmpty);
    await coordinator.controller.shutdown();
    await app.dispose();
  });

  group('resume restores the panel structure', () {
    // Seeds a session with one active primary conversation + [spawnCount] spawn
    // conversations + [branchCount] branch conversations, each carrying a q/a
    // history. Returns the session id and the primary conversation id.
    //
    // A branch seeds its `.jsonl` with a COPY of the primary's history (the
    // coordinator's `recorder.replace(parent.history.toList())` does the same at
    // branch time) so the resumed branch replay exercises the fork-history path.
    Future<({String sessionId, String primaryId})> seedSession(
      MemorySessionStore store, {
      required int spawnCount,
      int branchCount = 0,
    }) async {
      final policy = PermissionPolicy();
      final sid = await store.createSession(providerId: 'anthropic');
      // Primary is created first so it becomes the active conversation.
      final primaryId = await store.createConversationWithMeta(
        sid,
        ConversationMetaInput.primary(
          providerId: 'anthropic',
          provider: FakeProvider.done(),
          policy: policy,
          systemPrompt: 'primary system',
          label: 'primary',
        ),
      );
      await store.append(
        sid,
        primaryId,
        Message(role: Role.user, content: [TextBlock('primary q')]),
      );
      await store.append(
        sid,
        primaryId,
        Message(role: Role.assistant, content: [TextBlock('primary a')]),
      );
      // Capture the primary's seeded history so branches can copy it.
      final primaryHistory = await store.loadConversation(sid, primaryId);

      for (var i = 0; i < spawnCount; i++) {
        final spawnId = await store.createConversationWithMeta(
          sid,
          ConversationMetaInput.spawn(
            providerId: 'anthropic',
            providerModel: 'anthropic-small',
            policy: policy,
            systemPrompt: 'spawn system',
            targetName: 'scout-$i',
            parentConversationId: primaryId,
          ),
        );
        await store.append(
          sid,
          spawnId,
          Message(role: Role.user, content: [TextBlock('spawn $i q')]),
        );
        await store.append(
          sid,
          spawnId,
          Message(role: Role.assistant, content: [TextBlock('spawn $i a')]),
        );
      }

      for (var i = 0; i < branchCount; i++) {
        final branchId = await store.createConversationWithMeta(
          sid,
          ConversationMetaInput.branch(
            providerId: 'anthropic',
            providerModel: 'anthropic-small',
            policy: policy,
            systemPrompt: 'branch system',
            targetName: 'research-$i',
            parentConversationId: primaryId,
          ),
        );
        // Seed the branch with the parent's history (a fork copy), then a
        // follow-up turn so the panel's own history is distinguishable from
        // the parent's.
        await store.append(sid, branchId, primaryHistory.first);
        await store.append(sid, branchId, primaryHistory.last);
        await store.append(
          sid,
          branchId,
          Message(role: Role.user, content: [TextBlock('branch $i q')]),
        );
        await store.append(
          sid,
          branchId,
          Message(role: Role.assistant, content: [TextBlock('branch $i a')]),
        );
      }
      return (sessionId: sid, primaryId: primaryId);
    }

    test(
      'the resumed active conversation rebuilds under its persisted model',
      () async {
        // A `/model` swap during the session persists the new ref into the
        // conversation meta. The ACTIVE conversation is built by create() (the
        // restore loop skips it), so it must read that meta — not silently fall
        // back to the config-default startup provider.
        final store = MemorySessionStore();
        final sid = await store.createSession(providerId: 'anthropic');
        final primaryId = await store.createConversationWithMeta(
          sid,
          const ConversationMetaInput(
            // A model the config default is NOT (the descriptor's default is
            // claude-sonnet-4-6), so falling back would be visible.
            model: 'anthropic/claude-3-opus-20240229',
            providerId: 'anthropic',
            label: 'claude-3-opus-20240229',
            kind: ConversationKind.primary,
            promptOverride: 'persisted system',
          ),
        );
        await store.append(
          sid,
          primaryId,
          const Message(role: Role.user, content: [TextBlock('primary q')]),
        );

        final io = FakeStdio()..hasTerminalValue = false;
        final config = Config.parse(['--resume', sid, '--backend', 'ansi']);
        // NO injected provider: the injected startup override wins over the
        // persisted ref by contract (AppComposition.buildStartupProvider), so
        // exercising the meta path means letting the registry build for real.
        final app = await buildAppComposition(
          config: config,
          registry: builtinRegistry(),
          store: store,
          environment: FakeEnvironment(
            env: {for (final e in Platform.environment.entries) e.key: e.value}
              ..['COCOON_UPDATE_CHECK'] = '0',
          ),
        );
        final coordinator = await TuiCoordinator.create(
          app: app,
          io: io,
          terminalGeometry: const FakeTerminalGeometry(columns: 120, lines: 24),
        );

        final conv = coordinator.sessionManager.activeConversation;
        expect(
          conv.provider.model,
          'claude-3-opus-20240229',
          reason:
              'the active conversation must resume under its persisted '
              'model ref, not the config default',
        );
      },
    );

    test(
      'tiled layout restores simultaneous panels without a sidebar',
      () async {
        final store = MemorySessionStore();
        final seeded = await seedSession(store, spawnCount: 2);
        final config = Config.parse([
          '--resume',
          seeded.sessionId,
          '--backend',
          'ansi',
          '--layout',
          'tiled',
        ]);
        final app = await buildAppComposition(
          config: config,
          registry: builtinRegistry(),
          provider: FakeProvider.done(),
          store: store,
        );
        final coordinator = await TuiCoordinator.create(
          app: app,
          io: FakeStdio()..hasTerminalValue = false,
          terminalGeometry: const FakeTerminalGeometry(columns: 120, lines: 40),
        );
        final manager = coordinator.panelManager;
        expect(manager.sidebar, isNull);
        expect(coordinator.screen.layout.sidebar.isEmpty, isTrue);
        expect(coordinator.screen.layout.isSplit, isTrue);
        expect(manager.allFrames, hasLength(3));
        expect(manager.allFrames.every((frame) => !frame.isParked), isTrue);
        expect(manager.primaryFrame.bounds.col, 0);
        expect(
          manager.spawnedFrames.first.bounds.col,
          greaterThan(manager.primaryFrame.bounds.col),
        );
        coordinator.focusManager.focusPanel(manager.spawnedFrames.first);
        expect(
          coordinator.sessionManager.activeConversationId,
          manager.spawnedFrames.first.conversationId,
        );
        expect(manager.allFrames.every((frame) => !frame.isParked), isTrue);
      },
    );

    test(
      'a session with spawns restores the sidebar and selected transcript',
      () async {
        final store = MemorySessionStore();
        final seeded = await seedSession(store, spawnCount: 2);
        final sid = seeded.sessionId;
        final primaryId = seeded.primaryId;

        final io = FakeStdio()..hasTerminalValue = false;
        final config = Config.parse(['--resume', sid, '--backend', 'ansi']);
        final app = await buildAppComposition(
          config: config,
          registry: builtinRegistry(),
          provider: FakeProvider.done(),
          store: store,
        );
        final coordinator = await TuiCoordinator.create(
          app: app,
          io: io,
          // Wide enough terminal that a right column actually appears (the info
          // box vanishes below splitThreshold).
          terminalGeometry: const FakeTerminalGeometry(columns: 120, lines: 24),
        );

        final layout = coordinator.screen.layout;
        expect(layout.isSplit, isFalse);
        expect(layout.sidebar.width, 24);
        final manager = coordinator.panelManager;
        final sidebar = manager.sidebar!;
        expect(
          sidebar.entries.map((e) => e.label),
          containsAll([
            'scout-0 (anthropic-small)',
            'scout-1 (anthropic-small)',
          ]),
        );
        expect(sidebar.entries.map((e) => e.depth), [0, 1, 1]);
        expect(coordinator.sessionManager.activeConversationId, primaryId);
        expect(manager.selectedFrame, same(manager.primaryFrame));
        expect(coordinator.spawnedPanels.every((p) => p.isParked), isTrue);

        final line = coordinator.editor.readLine('> ');
        await pumpEventQueue();
        coordinator.editor.loadEditState('main draft', 10);

        // Restored history is retained while hidden and rendered on selection.
        coordinator.focusManager.focusPanel(sidebar);
        sidebar.handleEvent(ArrowKey(ArrowDirection.down));
        expect(coordinator.focusManager.focused, same(sidebar));
        expect(manager.selectedFrame, same(coordinator.spawnedPanels.first));
        expect(
          coordinator.sessionManager.activeConversationId,
          coordinator.spawnedPanels.first.conversationId,
        );
        expect(io.written.toString(), contains('spawn 0 q'));
        coordinator.editor.loadEditState('scout draft', 11);
        sidebar.handleEvent(ArrowKey(ArrowDirection.down));
        expect(io.written.toString(), contains('spawn 1 q'));
        sidebar.handleEvent(ControlKey(ControlCode.enter));
        expect(
          coordinator.focusManager.focused,
          same(coordinator.spawnedPanels.last),
        );

        // Returning to a conversation restores its draft, and background
        // output is buffered until the conversation becomes visible again.
        final primary = coordinator.sessionManager.active.conversationById(
          primaryId,
        )!;
        primary.host.showMessage('background primary message\n');
        coordinator.focusManager.focusPanel(sidebar);
        sidebar.handleEvent(ArrowKey(ArrowDirection.up));
        expect(coordinator.editor.editState.buffer, 'scout draft');
        sidebar.handleEvent(ArrowKey(ArrowDirection.up));
        expect(coordinator.editor.editState.buffer, 'main draft');
        expect(io.written.toString(), contains('background primary message'));
        expect(manager.selectedFrame, same(manager.primaryFrame));
        sidebar.handleEvent(ControlKey(ControlCode.enter));
        io.feedBytes([0x0d]);
        expect(await line, 'main draft');
        coordinator.editor.close();
        manager.dispose();
      },
    );

    test(
      'a session with a branch resumes the branch panel with fork history',
      () async {
        // Regression: a `/branch` fork is its own ConversationKind and must
        // restore as a real panel whose transcript is the forked parent history
        // PLUS the branch's own follow-up turn. Asserts from create() output —
        // the panelize/replay loops run synchronously inside create().
        final store = MemorySessionStore();
        final seeded = await seedSession(store, spawnCount: 0, branchCount: 1);
        final sid = seeded.sessionId;
        final primaryId = seeded.primaryId;

        final io = FakeStdio()..hasTerminalValue = false;
        final config = Config.parse(['--resume', sid, '--backend', 'ansi']);
        final app = await buildAppComposition(
          config: config,
          registry: builtinRegistry(),
          provider: FakeProvider.done(),
          store: store,
        );
        final coordinator = await TuiCoordinator.create(
          app: app,
          io: io,
          terminalGeometry: const FakeTerminalGeometry(columns: 120, lines: 24),
        );

        // One branch panel restored (the branch role label + parent model ref).
        expect(coordinator.spawnedPanels, hasLength(1));
        expect(
          coordinator.sessionManager.activeConversationId,
          primaryId,
          reason: 'restoring a branch must not steal focus',
        );
        coordinator.focusManager.focusPanel(coordinator.spawnedPanels.single);
        final out = io.written.toString();
        expect(
          out,
          contains('research-0 (anthropic-small)'),
          reason: 'branch panel must restore with a branch role label',
        );

        // The branch's on-disk meta is ConversationKind.branch, linked to its
        // parent — the fork lineage is inspectable in the manifest.
        final branchMeta = store.metaFor(
          sid,
          coordinator.spawnedPanels.single.conversationId,
        )!;
        expect(
          branchMeta.kind,
          ConversationKind.branch,
          reason: 'a restored branch must keep its branch kind',
        );
        expect(
          branchMeta.parentConversationId,
          primaryId,
          reason: 'the branch must link back to its parent conversation',
        );

        // The forked parent history (primary q/a) replays into the branch panel,
        // followed by the branch's own follow-up turn.
        expect(
          out,
          contains('primary q'),
          reason: 'forked parent history must replay into the branch panel',
        );
        expect(
          out,
          contains('branch 0 a'),
          reason: 'the branch follow-up turn must replay',
        );

        // Selecting the branch changes the in-memory active conversation.
        expect(
          coordinator.sessionManager.active.activeConversationId,
          coordinator.spawnedPanels.single.conversationId,
        );
      },
    );

    test(
      'focusing a branched side panel does not corrupt the manifest anchor',
      () async {
        // Mirrors the spawn regression test: focusing a `/branch` panel routes
        // input to it (in-memory active flips) but the persisted manifest anchor
        // must remain the primary — otherwise resume would promote the branch to
        // the full-width slot and drop the real primary.
        final store = MemorySessionStore();
        final seeded = await seedSession(store, spawnCount: 0, branchCount: 1);
        final sid = seeded.sessionId;
        final primaryId = seeded.primaryId;

        final io = FakeStdio()..hasTerminalValue = false;
        final config = Config.parse(['--resume', sid, '--backend', 'ansi']);
        final app = await buildAppComposition(
          config: config,
          registry: builtinRegistry(),
          provider: FakeProvider.done(),
          store: store,
        );
        final coordinator = await TuiCoordinator.create(
          app: app,
          io: io,
          terminalGeometry: const FakeTerminalGeometry(columns: 120, lines: 24),
        );

        final branchPanel = coordinator.spawnedPanels.single;
        coordinator.focusManager.focusPanel(branchPanel);
        // In-memory active is now the branch panel...
        expect(
          coordinator.sessionManager.active.activeConversationId,
          branchPanel.conversationId,
          reason: 'focusing a branch panel must route input to it',
        );
        // ...but the persisted manifest anchor must stay the primary.
        final manifest = await store.loadSession(sid);
        expect(
          manifest.activeConversationId,
          primaryId,
          reason: 'the manifest anchor must stay the primary, not the branch',
        );
      },
    );

    test('a session with no spawns resumes unsplit', () async {
      final store = MemorySessionStore();
      final sid = await store.createSession(providerId: 'anthropic');
      await store.createConversationWithMeta(
        sid,
        ConversationMetaInput.primary(
          providerId: 'anthropic',
          provider: FakeProvider.done(),
          policy: PermissionPolicy(),
          systemPrompt: 'primary system',
          label: 'primary',
        ),
      );

      final io = FakeStdio()..hasTerminalValue = false;
      final config = Config.parse(['--resume', sid, '--backend', 'ansi']);
      final app = await buildAppComposition(
        config: config,
        registry: builtinRegistry(),
        provider: FakeProvider.done(),
        store: store,
      );
      final coordinator = await TuiCoordinator.create(
        app: app,
        io: io,
        terminalGeometry: const FakeTerminalGeometry(columns: 80, lines: 24),
      );

      // No spawns, no sub-agents → no panels → layout stays full-width.
      expect(
        coordinator.screen.layout.isSplit,
        isFalse,
        reason: 'a session with no side panels must not split',
      );
    });

    test(
      'focusing a side panel does not corrupt the manifest anchor',
      () async {
        // Regression: focusing a spawned side panel routes input to it but must
        // NOT repoint the session manifest's activeConversationId at it. That
        // anchor decides which conversation becomes the full-width slot on
        // resume; if a side panel became the anchor, resume would promote it to
        // the full-width slot and drop the real primary to a background replay
        // with no panel. (This is exactly what produced the on-disk manifest
        // whose activeConversationId pointed at a spawn.)
        final store = MemorySessionStore();
        final seeded = await seedSession(store, spawnCount: 2);
        final sid = seeded.sessionId;
        final primaryId = seeded.primaryId;

        final io = FakeStdio()..hasTerminalValue = false;
        final config = Config.parse(['--resume', sid, '--backend', 'ansi']);
        final app = await buildAppComposition(
          config: config,
          registry: builtinRegistry(),
          provider: FakeProvider.done(),
          store: store,
        );
        final coordinator = await TuiCoordinator.create(
          app: app,
          io: io,
          terminalGeometry: const FakeTerminalGeometry(columns: 120, lines: 24),
        );

        final spawnPanel = coordinator.spawnedPanels.first;
        // Drive the real focus path the same way openSpawn's focusPanel does.
        coordinator.focusManager.focusPanel(spawnPanel);
        // Input routing follows focus (in-memory active is now the spawn)...
        expect(
          coordinator.sessionManager.active.activeConversationId,
          spawnPanel.conversationId,
          reason: 'focusing a side panel must route input to it',
        );
        // ...but the persisted manifest anchor must remain the primary.
        final manifest = await store.loadSession(sid);
        expect(
          manifest.activeConversationId,
          primaryId,
          reason: 'the manifest anchor must stay the primary, not the panel',
        );
      },
    );

    // --- Phase 0 characterization (safety net for the panel-abstraction
    // refactor). These pin the tiling math and input-relocation behavior that
    // Phase 3 will move out of create() into PanelManager, so the move cannot
    // silently change panel geometry or where the shared input lands. ---

    test(
      'sidebar selection gives each conversation the full transcript area',
      () async {
        final store = MemorySessionStore();
        final seeded = await seedSession(store, spawnCount: 3);
        final io = FakeStdio()..hasTerminalValue = false;
        final config = Config.parse([
          '--resume',
          seeded.sessionId,
          '--backend',
          'ansi',
        ]);
        final app = await buildAppComposition(
          config: config,
          registry: builtinRegistry(),
          provider: FakeProvider.done(),
          store: store,
        );
        // 44 lines so all three panels fit at the column's minimum height —
        // this pins the FIT case; the scroll case (panels exceed the column,
        // window + min height 10) is pinned in panel_manager_test.dart.
        final coordinator = await TuiCoordinator.create(
          app: app,
          io: io,
          terminalGeometry: const FakeTerminalGeometry(columns: 120, lines: 44),
        );

        final layout = coordinator.screen.layout;
        expect(layout.isSplit, isFalse);
        final panels = coordinator.treeOrderedPanels;
        expect(panels, hasLength(3));
        final manager = coordinator.panelManager;
        final sidebar = manager.sidebar!;
        coordinator.focusManager.focusPanel(sidebar);
        for (final panel in panels) {
          sidebar.handleEvent(ArrowKey(ArrowDirection.down));
          expect(manager.selectedFrame, same(panel));
          expect(panel.isParked, isFalse);
          expect(panel.bounds.col, layout.sidebar.width);
          expect(panel.bounds.right, layout.width - 1);
          expect(panel.bounds.row, layout.topBorderRow);
          expect(panel.bounds.bottom, layout.bottomBorderRow);
          expect(manager.allFrames.where((p) => !p.isParked), [panel]);
          expect(manager.primaryFrame.canFocus, isFalse);
          expect(coordinator.screen.input.bounds.row, panel.inputRect.row);
        }
      },
    );

    test(
      'relocateInput repoints the shared input region onto the focused panel',
      () async {
        // Characterization of the input-relocation half of create() that Phase 3
        // will extract into PanelManager. We assert the observable effect — the
        // shared InputRegion retargets to the focused panel's inputRect — by
        // driving the real focus path, since relocateInput is a closure nested in
        // create() and cannot be called directly. (The editor buffer/cursor
        // save-restore branch only fires during an active edit session, which the
        // create()-only harness does not reach, so it is intentionally not
        // covered here.)
        final store = MemorySessionStore();
        final seeded = await seedSession(store, spawnCount: 2);
        final io = FakeStdio()..hasTerminalValue = false;
        final config = Config.parse([
          '--resume',
          seeded.sessionId,
          '--backend',
          'ansi',
        ]);
        final app = await buildAppComposition(
          config: config,
          registry: builtinRegistry(),
          provider: FakeProvider.done(),
          store: store,
        );
        final coordinator = await TuiCoordinator.create(
          app: app,
          io: io,
          terminalGeometry: const FakeTerminalGeometry(columns: 120, lines: 24),
        );

        final panels = coordinator.spawnedPanels;
        final a = panels[0];
        final b = panels[1];

        coordinator.focusManager.focusPanel(a);
        await pumpEventQueue();
        expect(
          coordinator.screen.input.bounds.row,
          a.inputRect.row,
          reason: 'focus a: row',
        );
        expect(
          coordinator.screen.input.bounds.col,
          a.inputRect.col,
          reason: 'focus a: col',
        );
        expect(
          coordinator.screen.input.bounds.width,
          a.inputRect.width,
          reason: 'focus a: width',
        );
        expect(
          coordinator.screen.input.bounds.height,
          a.inputRect.height,
          reason: 'focus a: height',
        );

        coordinator.focusManager.focusPanel(b);
        await pumpEventQueue();
        expect(
          coordinator.screen.input.bounds.row,
          b.inputRect.row,
          reason: 'focus b: row',
        );
        expect(
          coordinator.screen.input.bounds.col,
          b.inputRect.col,
          reason: 'focus b: col',
        );
        expect(
          coordinator.screen.input.bounds.width,
          b.inputRect.width,
          reason: 'focus b: width',
        );
        expect(
          coordinator.screen.input.bounds.height,
          b.inputRect.height,
          reason: 'focus b: height',
        );

        coordinator.focusManager.focusPanel(a);
        await pumpEventQueue();
        expect(
          coordinator.screen.input.bounds.row,
          a.inputRect.row,
          reason: 'refocus a: row',
        );
        expect(
          coordinator.screen.input.bounds.col,
          a.inputRect.col,
          reason: 'refocus a: col',
        );
        expect(
          coordinator.screen.input.bounds.width,
          a.inputRect.width,
          reason: 'refocus a: width',
        );
        expect(
          coordinator.screen.input.bounds.height,
          a.inputRect.height,
          reason: 'refocus a: height',
        );
      },
    );
  });

  group('live /branch fork', () {
    // The resume-path tests above cover a branch that was *restored* from disk.
    // This group drives the real `controller.openBranch` callback — the live
    // fork body that copies the parent's history into a fresh side panel — with
    // an injected `spawnTargetPicker` so the terminal overlays don't run. The
    // parent's history is seeded via the resume path (so the live primary
    // actually carries turns to fork), but the fork itself is the live action.
    //
    // The fork body re-derives user config (loadUserConfig) and builds a real
    // provider from the registry; it never sends a turn, so a placeholder key
    // is fine. We point HOME at a temp dir whose `~/.tina/config` declares
    // the anthropic provider + a test key so the fork's config read resolves.

    test(
      'copies the parent conversation full history into the branch panel',
      () async {
        final store = MemorySessionStore();
        // Seed a primary conversation with a multi-turn history the fork will copy.
        final policy = PermissionPolicy();
        final sid = await store.createSession(providerId: 'anthropic');
        final primaryId = await store.createConversationWithMeta(
          sid,
          ConversationMetaInput.primary(
            providerId: 'anthropic',
            provider: FakeProvider.done(),
            policy: policy,
            systemPrompt: 'primary system',
            label: 'primary',
          ),
        );
        await store.append(
          sid,
          primaryId,
          Message(role: Role.user, content: [TextBlock('parent turn one')]),
        );
        await store.append(
          sid,
          primaryId,
          Message(
            role: Role.assistant,
            content: [TextBlock('parent reply one')],
          ),
        );
        await store.append(
          sid,
          primaryId,
          Message(role: Role.user, content: [TextBlock('parent turn two')]),
        );
        await store.append(
          sid,
          primaryId,
          Message(
            role: Role.assistant,
            content: [TextBlock('parent reply two')],
          ),
        );

        // Temp HOME with a `~/.tina/config` declaring anthropic + a test key.
        final tempHome = await Directory.systemTemp.createTemp(
          'tina_branch_test_',
        );
        addTearDown(() => tempHome.delete(recursive: true));
        writeUserConfig(
          const UserConfig(
            providers: {'anthropic': ProviderConfig(apiKey: 'test-key')},
          ),
          env: const {'HOME': '/__unused__'}, // env unused; tinaDir is explicit
          tinaDir: Directory('${tempHome.path}/.tina'),
        );
        final environment = FakeEnvironment(env: {'HOME': tempHome.path});

        final io = FakeStdio()..hasTerminalValue = false;
        final config = Config.parse(['--resume', sid, '--backend', 'ansi']);
        final app = await buildAppComposition(
          config: config,
          registry: builtinRegistry(),
          provider: FakeProvider.done(),
          store: store,
          environment: environment,
        );

        // The tool profile the live fork would have picked from the overlay. The
        // model ref resolves against the anthropic descriptor the registry was
        // built with.
        const pickedProfile = ToolProfile.full;
        final coordinator = await TuiCoordinator.create(
          app: app,
          io: io,
          terminalGeometry: const FakeTerminalGeometry(columns: 120, lines: 24),
          spawnTargetPicker: () async =>
              (ref: 'anthropic/claude-sonnet-4-6', profile: pickedProfile),
        );

        final primary = coordinator.sessionManager.activeConversation;
        final parentHistory = primary.history.toList();
        expect(
          parentHistory.length,
          greaterThan(0),
          reason: 'precondition: the live primary must carry seeded history',
        );

        // Drive the real live fork callback — this is the untested path.
        await coordinator.controller.openBranch!();

        // A branch panel materialized in the right column.
        expect(
          coordinator.spawnedPanels.length,
          1,
          reason: 'the fork must add exactly one branch panel',
        );
        final branchPanel = coordinator.spawnedPanels.single;
        final branch = coordinator.sessionManager.active.conversationById(
          branchPanel.conversationId,
        );
        expect(
          branch,
          isNotNull,
          reason: 'the branch panel must resolve to a conversation',
        );

        // The fork copied the parent's FULL history into the branch, verbatim
        // and in order — this is the core "fork copies history" invariant.
        final branchTexts = branch!.history
            .map(
              (m) => m.content.whereType<TextBlock>().map((b) => b.text).join(),
            )
            .toList();
        final parentTexts = parentHistory
            .map(
              (m) => m.content.whereType<TextBlock>().map((b) => b.text).join(),
            )
            .toList();
        expect(
          branchTexts.length,
          parentTexts.length,
          reason: 'branch must have the same message count as the parent',
        );
        for (var i = 0; i < parentTexts.length; i++) {
          expect(
            branchTexts[i],
            parentTexts[i],
            reason: 'branch message $i must equal the parent\'s (full copy)',
          );
        }

        // The forked history must RENDER into the branch panel — not just exist
        // in the Conversation's in-memory list. Without replayHistory the panel
        // is blank even though branch.history is populated (the bug: history
        // sends to the model but nothing paints the chat region). Assert on the
        // byte stream the host flushed, like the restore-path tests do.
        final out = io.written.toString();
        for (final text in parentTexts) {
          expect(
            out,
            contains(text),
            reason: 'forked history "$text" must render into the branch panel',
          );
        }

        // The parent is left untouched — its history is unchanged by the fork.
        expect(
          primary.history.length,
          parentHistory.length,
          reason: 'the parent history must not change when forked',
        );
        // Focus moves to the new branch panel (the user just forked), so the
        // in-memory active conversation is the branch...
        expect(
          coordinator.sessionManager.active.activeConversationId,
          branchPanel.conversationId,
          reason: 'the fork must focus the new branch panel',
        );
        // ...but the persisted manifest anchor stays the primary — the fork must
        // not promote the branch to the full-width slot on resume. This is the
        // "original continues untouched" invariant (onPanelFocused with
        // persist:false leaves the anchor on the parent).
        final manifest = await store.loadSession(sid);
        expect(
          manifest.activeConversationId,
          primaryId,
          reason: 'the manifest anchor must stay the parent, not the branch',
        );

        // The branch persists on disk with its own id, kind=branch, linked to
        // the parent — so it resumes as a branch, not a fresh conversation.
        final branchMeta = manifest.conversations.firstWhere(
          (m) => m.id == branchPanel.conversationId,
        );
        expect(branchMeta.kind, ConversationKind.branch);
        expect(branchMeta.parentConversationId, primaryId);
      },
    );
  });

  // Regression for the "delegate opens no panel on a fresh run" bug. On a fresh
  // start the primary session is a placeholder id that does NOT exist in the
  // store yet (the recorder materializes it lazily on the first append). The
  // coordinator's sub-agent persistence factory must `ensureRegistered()` the
  // primary before minting the sub-agent conversation — exactly the /spawn path
  // — and use the recorder's real on-disk session id (which diverges from the
  // in-memory placeholder until the first write). Without that guard the
  // factory's `createConversationWithMeta(<placeholder>, …)` throws `Session
  // not found`; `_persistJob` swallows the throw, so panelHost/panelSink stay
  // null and the sub-agent streams into the parent chat instead of opening a
  // panel. (MemorySessionStore mirrors the real store's throw-on-missing.)
  //
  // We drive the REAL coordinator factory directly — it is wired onto
  // `coordinator.subAgentScheduler.persistence` during create() — rather than
  // running a live turn, which avoids the line-editor/input harness entirely
  // while still exercising the exact code path the fix touches.
  group('delegate panelization on a fresh run', () {
    test(
      'the persistence factory materializes the primary and opens a panel',
      () async {
        // A fresh run: no --resume, empty store. The primary's session id is a
        // placeholder the store has never seen.
        final store = MemorySessionStore();
        final io = FakeStdio()..hasTerminalValue = false;
        final config = Config.parse(const ['--backend', 'ansi']);
        final app = await buildAppComposition(
          config: config,
          registry: builtinRegistry(),
          provider: FakeProvider.done(),
          store: store,
        );
        final coordinator = await TuiCoordinator.create(
          app: app,
          io: io,
          terminalGeometry: const FakeTerminalGeometry(columns: 120, lines: 24),
        );

        // The factory the scheduler calls when main delegates to an agent role.
        final factory = coordinator.subAgentScheduler.persistence;
        expect(
          factory,
          isNotNull,
          reason:
              'precondition: the coordinator must wire the persistence '
              'factory so delegated sub-agents get panels',
        );

        // A fabricated sub-agent job + meta, as the scheduler would build them.
        final job = SubAgentJob(
          id: 'j-test',
          label: 'scout',
          systemPrompt: 'scout identity',
          toolProfile: ToolProfile.readOnly,
          modelReference: 'anthropic/claude-haiku-4-5',
          originConversationId:
              coordinator.sessionManager.active.activeConversationId,
          parentReference: 'anthropic/claude-haiku-4-5',
          parentPolicy: PermissionPolicy(),
          depth: 1,
          result: Completer<DelegationResult>(),
          bus: AgentEventBus(),
          cancel: Completer<void>(),
        );
        final meta = ConversationMetaInput.subAgent(
          model: 'anthropic/claude-haiku-4-5',
          providerId: 'anthropic',
          policy: PermissionPolicy(),
          systemPrompt: 'scout system',
          targetName: 'scout',
          parentConversationId:
              coordinator.sessionManager.active.activeConversationId,
        );

        // Invoke the real factory. Before the fix this throws inside
        // createConversationWithMeta and the throw would be swallowed by the
        // scheduler's _persistJob — but here we call the factory directly, so a
        // missing-session throw surfaces as a test failure (and the panel fields
        // stay null). After the fix it materializes the primary and stashes the
        // panel host + sink.
        await factory!(
          job,
          meta: meta,
          parentConversationId:
              coordinator.sessionManager.active.activeConversationId,
        );

        expect(
          job.panelSink,
          isNotNull,
          reason:
              'the factory must stash a panel sink so the sub-agent '
              'streams into its panel, not the parent chat',
        );
        expect(
          job.panelHost,
          isNotNull,
          reason:
              'the factory must stash a panel host so the scheduler can '
              'build the sub-agent as a first-class session',
        );
        // A panel frame was created for the sub-agent.
        expect(
          coordinator.spawnedPanels,
          isNotEmpty,
          reason: 'a delegated sub-agent must open its own panel',
        );
        // The panel title names both the role and the model (provider prefix
        // dropped), like every other conversation panel.
        expect(
          coordinator.spawnedPanels.single.label,
          'scout (claude-haiku-4-5)',
          reason: 'a delegated sub-agent panel must show role + model',
        );
      },
    );

    test('every panel title shows the role and the model', () async {
      final store = MemorySessionStore();
      final io = FakeStdio()..hasTerminalValue = false;
      final config = Config.parse(const ['--backend', 'ansi']);
      final app = await buildAppComposition(
        config: config,
        registry: builtinRegistry(),
        provider: FakeProvider.done(),
        store: store,
      );
      final coordinator = await TuiCoordinator.create(
        app: app,
        io: io,
        terminalGeometry: const FakeTerminalGeometry(columns: 120, lines: 24),
      );

      // The primary panel titles as `main role (model)` — not the bare model.
      final primary = coordinator.panelManager.primaryFrame;
      expect(
        primary.label,
        contains('('),
        reason: 'primary panel title must include the model in parens',
      );
      expect(
        primary.label,
        startsWith('main'),
        reason: 'primary panel title must start with the main role name',
      );
    });
  });

  group('Shift+Tab permission-mode cycling', () {
    // Owner feature 2026-08-24: Shift+Tab (CSI Z backtab) cycles the
    // permission modes ask → read-all → allow-edits → auto → ask — the same
    // switch `/permissions <mode>` performs, announced with the same message
    // line. Driven end-to-end through the real REPL over real bytes.
    test(
      'four presses walk the ring and wrap home, announcing each step',
      () async {
        final io = FakeStdio()..hasTerminalValue = false;
        final config = Config.parse(const ['--backend', 'ansi']);
        final app = await buildAppComposition(
          config: config,
          registry: builtinRegistry(),
          provider: FakeProvider.done(),
          store: MemorySessionStore(),
        );
        final coordinator = await TuiCoordinator.create(
          app: app,
          io: io,
          terminalGeometry: const FakeTerminalGeometry(columns: 80, lines: 24),
        );
        coordinator.pendingFirstLoadEnvironmentAsk = null;

        // Four Shift+Tabs (ask → read-all → allow-edits → auto → ask), then
        // /exit: Enter accepts the command picker's suggestion, Enter submits.
        const backtab = [0x1b, 0x5b, 0x5a];
        io.feedBytes([
          ...backtab,
          ...backtab,
          ...backtab,
          ...backtab,
          0x2f, 0x65, 0x78, 0x69, 0x74, // /exit
          0x0d,
          0x0d,
        ]);

        await coordinator.run().timeout(const Duration(seconds: 5));

        // The base policy landed back on ask after wrapping the whole ring…
        expect(app.policy.mode, PermissionMode.ask);
        // …and the ring was walked in order: each press announced the mode it
        // switched TO (the message line /permissions prints).
        final out = io.written.toString();
        final lines = [
          for (final label in ['read-all', 'allow-edits', 'auto', 'ask'])
            out.indexOf('permission mode: $label'),
        ];
        for (final i in lines) {
          expect(i, greaterThanOrEqualTo(0), reason: 'each step was announced');
        }
        // Strictly increasing: read-all before allow-edits before auto before
        // the wrapping ask.
        expect(lines[0], lessThan(lines[1]));
        expect(lines[1], lessThan(lines[2]));
        expect(lines[2], lessThan(lines[3]));
      },
    );

    test('one press from ask lands on read-all on the base policy', () async {
      final io = FakeStdio()..hasTerminalValue = false;
      final config = Config.parse(const ['--backend', 'ansi']);
      final app = await buildAppComposition(
        config: config,
        registry: builtinRegistry(),
        provider: FakeProvider.done(),
        store: MemorySessionStore(),
      );
      final coordinator = await TuiCoordinator.create(
        app: app,
        io: io,
        terminalGeometry: const FakeTerminalGeometry(columns: 80, lines: 24),
      );
      coordinator.pendingFirstLoadEnvironmentAsk = null;

      io.feedBytes([
        0x1b, 0x5b, 0x5a, // Shift+Tab
        0x2f, 0x65, 0x78, 0x69, 0x74, 0x0d, 0x0d,
      ]);

      await coordinator.run().timeout(const Duration(seconds: 5));

      expect(
        app.policy.mode,
        PermissionMode.readAll,
        reason: 'a single Shift+Tab steps ask → read-all',
      );
      expect(io.written.toString(), contains('permission mode: read-all'));
    });
  });

  test(
    'Ctrl+C cancels a background approval without quitting the app',
    () async {
      final io = FakeStdio()..hasTerminalValue = false;
      final app = await buildAppComposition(
        config: Config.parse(const ['--backend', 'ansi']),
        registry: builtinRegistry(),
        provider: FakeProvider.done(),
        store: MemorySessionStore(),
        environment: FakeEnvironment(
          env: Map.of(Platform.environment)..['COCOON_UPDATE_CHECK'] = '0',
        ),
      );
      final coordinator = await TuiCoordinator.create(
        app: app,
        io: io,
        terminalGeometry: const FakeTerminalGeometry(columns: 120, lines: 24),
      );
      coordinator.pendingFirstLoadEnvironmentAsk = null;
      coordinator.pendingGitignoreAsk = null;
      var exited = false;
      final run = coordinator.run().then((_) => exited = true);
      await pumpEventQueue();
      final editor = coordinator.editor;
      final asker = WorkflowPermissionAsker(
        sink: coordinator.sessionManager.activeConversation.host,
        screen: coordinator.screen,
        editor: editor,
      );
      PermissionResponse? response;
      final job = coordinator.controller.jobs.start('index', 'index-test', (
        job,
      ) async {
        response = await asker.ask(
          PermissionPrompt('bash', {'command': 'pwd'}),
        );
        await job.cancelled;
      })!;
      await pumpEventQueue();
      expect(editor.isReadingKey, isTrue);
      // Cancellation also works while the focus ring is navigating the sidebar.
      coordinator.focusManager.focusPanel(coordinator.panelManager.sidebar!);
      io.feedBytes([0x07]);
      await pumpEventQueue();
      io.feedBytes([0x03]);
      await job.done.timeout(const Duration(seconds: 2));
      expect(job.cancellationRequested, isTrue);
      expect(response, PermissionResponse.denyOnce);
      expect(editor.isReadingKey, isFalse);
      expect(exited, isFalse);
      expect(coordinator.controller.isEnvironmentRunning, isFalse);

      // Once idle, Ctrl+C retains the existing quit confirmation.
      coordinator.focusManager.cancel();
      coordinator.focusManager.focusPanel(
        coordinator.panelManager.primaryFrame,
      );
      io.feedBytes([0x03, 0x03]);
      await run.timeout(const Duration(seconds: 5));
      io.close();
    },
  );

  group('double-Esc force-cancels through an open approval', () {
    // Owner bug 2026-08-24: "I pressed Escape twice and the border was still
    // animating." A bash approval was open; its readKey loop eats single Escs
    // as "deny", the model re-issued the denied call, and nothing ever
    // stopped the turn. The parser must emit one EscapeKey per rapid press,
    // the editor's 450ms double window must survive the readKey swipe, and
    // the second Esc must force-cancel the run underneath the modal.
    test('rapid Esc-Esc across two approvals stops the turn', () async {
      final io = FakeStdio()..hasTerminalValue = false;
      final config = Config.parse(const ['--backend', 'ansi']);
      // Each response re-issues the same denied bash call — the exact
      // circuit-breaker shape (#27) that kept the comet sweeping.
      List<StreamEvent> toolTurn(String id) => [
        MessageComplete(
          content: [
            ToolUseBlock(
              id: id,
              name: 'bash',
              input: const {'command': 'echo hi'},
            ),
          ],
          stopReason: 'tool_use',
        ),
      ];
      final app = await buildAppComposition(
        config: config,
        registry: builtinRegistry(),
        provider: FakeProvider([toolTurn('c1'), toolTurn('c2')]),
        store: MemorySessionStore(),
        // Hermeticity: the background update check probes GitHub and drops a
        // banner into the chat — a real release (0.4.1, 2026-08-24) landed it
        // between the approval and the first Esc, breaking the echo this test
        // pumps for. Timing-sensitive TUI tests must not see the network.
        environment: FakeEnvironment(
          env: {for (final e in Platform.environment.entries) e.key: e.value}
            ..['COCOON_UPDATE_CHECK'] = '0',
        ),
      );
      final coordinator = await TuiCoordinator.create(
        app: app,
        io: io,
        terminalGeometry: const FakeTerminalGeometry(columns: 80, lines: 24),
      );
      coordinator.pendingFirstLoadEnvironmentAsk = null;

      int countOf(String needle) =>
          needle.allMatches(io.written.toString().replaceAll('\n', ' ')).length;

      Future<void> pumpUntil(
        bool Function() cond, {
        Duration timeout = const Duration(seconds: 5),
      }) async {
        final deadline = DateTime.now().add(timeout);
        while (!cond()) {
          if (DateTime.now().isAfter(deadline)) {
            fail(
              'pumpUntil timed out after ${timeout.inSeconds}s; output '
              'tail:\n${io.written.toString().split('\n').skip(0).join('\n')}',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }

      // The two Escs are separated by pump polling whose latency varies
      // with code layout (a fresh kernel compile can flip this test), so the
      // double-Esc window is widened for the run — the gesture semantics
      // (deny, force-cancel, unwind) are what's under test, not the 450ms.
      LineEditor.debugDoubleEscWindow = const Duration(seconds: 5);
      final runFuture = coordinator.run().timeout(const Duration(seconds: 20));

      io.feedBytes([0x68, 0x69, 0x0d]); // hi + Enter — starts the turn
      await pumpUntil(() => countOf('approve?') >= 1); // approval #1 armed

      io.feedBytes([0x1b]); // first Esc: denies approval #1
      await pumpUntil(() => countOf(' esc') >= 1); // deny echo landed

      // The model re-issues the denied call — approval #2 arms.
      await pumpUntil(() => countOf('approve?') >= 2);

      io.feedBytes([0x1b]); // second Esc, inside the widened window
      // The turn MUST stop: force-cancel + the denial unwind. The end state
      // (cancelled vs denied-to-completion) races the double-Esc force-cancel
      // against the modal's own deny, so pin the invariant — not running —
      // rather than one specific ending's echo.
      await pumpUntil(
        () => !coordinator.sessionManager.activeConversation.isRunning,
        timeout: const Duration(seconds: 10),
      );
      LineEditor.debugDoubleEscWindow = null;

      // Let the turn teardown settle before driving the prompt — keys fed
      // mid-unwind are swallowed (queued/ignored) and the loop never sees
      // the /exit.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      io.feedBytes([0x2f, 0x65, 0x78, 0x69, 0x74, 0x0d]); // /exit + accept
      await Future<void>.delayed(const Duration(milliseconds: 250));
      io.feedBytes([0x0d]); // submit
      await runFuture;

      final out = io.written.toString();
      expect(
        out,
        contains('[cancelled]'),
        reason: 'the double-Esc force-cancelled turn is indicated',
      );
      expect(
        out,
        contains('approve?'),
        reason: 'sanity: the approval row really opened',
      );
    });
  });

  group('openModelPicker: offer the pick as the global default', () {
    /// A coordinator over a temp HOME whose `~/.tina/config` declares one
    /// configured provider with its single model explicitly enabled, so the
    /// picker shows exactly `anthropic/claude-sonnet-4-6`.
    Future<({TuiCoordinator coordinator, FakeStdio io, Directory home})>
    setUpPicker({UserConfig? seed}) async {
      final home = await Directory.systemTemp.createTemp('tina_model_default_');
      addTearDown(() => home.delete(recursive: true));
      final env = {'HOME': home.path};
      writeUserConfig(
        seed ??
            const UserConfig(
              providers: {
                'anthropic': ProviderConfig(
                  apiKey: 'test-key',
                  disabledModels: {},
                ),
              },
            ),
        env: env,
      );
      final io = FakeStdio()..hasTerminalValue = false;
      final app = await buildAppComposition(
        config: Config.parse(const ['--backend', 'ansi']),
        registry: builtinRegistry(),
        provider: FakeProvider.done(),
        store: MemorySessionStore(),
        environment: FakeEnvironment(env: env),
      );
      final coordinator = await TuiCoordinator.create(
        app: app,
        io: io,
        terminalGeometry: const FakeTerminalGeometry(columns: 120, lines: 24),
      );
      return (coordinator: coordinator, io: io, home: home);
    }

    test(
      'confirming Yes persists [default] and preserves [providers]',
      () async {
        final t = await setUpPicker();
        // Enter picks the highlighted model, then — once the confirm has armed —
        // Enter accepts it (Yes is focused first).
        t.io.feedBytes([0x0d]);
        t.io.feedLater([0x0d], const Duration(milliseconds: 300));
        await t.coordinator.controller.openModelPicker!();
        final saved = loadUserConfig(env: {'HOME': t.home.path});
        expect(saved.defaultProvider, 'anthropic');
        expect(saved.defaultModel, 'claude-sonnet-4-6');
        // The read-modify-write keeps the provider block (and the enabled set).
        expect(saved.providers['anthropic']?.apiKey, 'test-key');
        expect(saved.providers['anthropic']?.disabledModels, isEmpty);
      },
    );

    test(
      'answering No leaves the config untouched (switch still applies)',
      () async {
        final t = await setUpPicker();
        // Enter picks; then Down moves to No; Enter accepts.
        t.io.feedBytes([0x0d]);
        t.io.feedLater([
          0x1b,
          0x5b,
          0x42,
          0x0d,
        ], const Duration(milliseconds: 300));
        await t.coordinator.controller.openModelPicker!();
        final saved = loadUserConfig(env: {'HOME': t.home.path});
        expect(saved.defaultProvider, isNull);
        expect(saved.defaultModel, isNull);
        expect(saved.providers['anthropic']?.apiKey, 'test-key');
      },
    );

    test('picking the stored default asks nothing', () async {
      final t = await setUpPicker(
        seed: const UserConfig(
          defaultProvider: 'anthropic',
          defaultModel: 'claude-sonnet-4-6',
          providers: {
            'anthropic': ProviderConfig(apiKey: 'test-key', disabledModels: {}),
          },
        ),
      );
      // ONE Enter: a second would only be needed if the confirm opened, so the
      // call returning at all proves the prompt was skipped.
      t.io.feedBytes([0x0d]);
      await t.coordinator.controller.openModelPicker!();
      final saved = loadUserConfig(env: {'HOME': t.home.path});
      expect(saved.defaultProvider, 'anthropic');
      expect(saved.defaultModel, 'claude-sonnet-4-6');
    });
  });
}
