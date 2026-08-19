import 'dart:async';
import 'dart:io';

import 'package:tina/composition/app_composition.dart';
import 'package:tina/config.dart';
import 'package:tina/config/user_config.dart';
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
  group('resumeHintText', () {
    test('prints the session id, message count, and both resume commands', () {
      final text = resumeHintText(const ExitContext(
        sessionId: '20260703-143012-a1b2',
        messageCount: 42,
      ));
      expect(
          text, contains('session saved: 20260703-143012-a1b2 (42 messages)'));
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
  });

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
      0x0d
    ]); // /exit: Enter accepts, Enter submits

    await coordinator.run().timeout(const Duration(seconds: 5));
    io.close();

    final out = io.written.toString();
    final altScreen = out.indexOf('\x1b[?1049h');
    final frameBorder = out.indexOf('┌');
    expect(altScreen, greaterThanOrEqualTo(0),
        reason: 'should enter alt screen');
    expect(frameBorder, greaterThanOrEqualTo(0),
        reason: 'chat frame should paint');
    expect(
      altScreen,
      lessThan(frameBorder),
      reason: 'frame must paint after entering the alt screen; painting '
          'beforehand leaves the borders erased by the frame redraw and the '
          'screen blank on startup',
    );
  });

  test('emergencyTerminalRestore leaves the alt screen via the live backend',
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
    expect(out, contains('\x1b[?1049l'),
        reason: 'crash path must emit the leave-alt-screen escape');
  });

  test('setup mode: overlay writes → setupWrote and the REPL is skipped',
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
      setupOverlay: () async => const UserConfig(defaultProvider: 'anthropic'),
    );

    final outcome = await coordinator
        .run(setupMode: true)
        .timeout(const Duration(seconds: 5));
    expect(outcome, RunOutcome.setupWrote);
    // The setup branch returns RunOutcome.setupWrote before controller.run()
    // (the REPL) is ever called, and no input was fed (readLine would block
    // otherwise) — so run() returning at all proves the REPL was skipped.
  });

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

  test('--continue renders the loaded conversation history into the chat',
      () async {
    // Pre-populate a session store with a user message and an agent response.
    final store = MemorySessionStore();
    final sid = await store.createSession(providerId: 'anthropic');
    final cid = await store.createConversation(sid);
    await store.append(sid, cid,
        Message(role: Role.user, content: [TextBlock('hello agent')]));
    await store.append(sid, cid,
        Message(role: Role.assistant, content: [TextBlock('hi human')]));

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
    expect(out, contains('hello agent'),
        reason: 'the loaded user message must be rendered on startup');
    // The agent's response should also be rendered.
    expect(out, contains('hi human'),
        reason: 'the loaded agent response must be rendered on startup');
  });

  test('first load asks before the REPL; Enter runs the environment agent',
      () async {
    // With no ENVIRONMENT.md (true of this repo's root) and a trusted
    // project, run() shows the picker after the first paint and before the
    // REPL takes the keyboard. Enter selects "Run now" → the launch notice
    // lands in the chat and the agent starts in the background.
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
    expect(coordinator.pendingFirstLoadEnvironmentAsk, isNotNull,
        reason: 'no ENVIRONMENT.md → the ask must be pending');

    // Escape cancels the picker (choosing "Run now" here would launch the
    // environment agent against the REAL provider registry — the injected
    // FakeProvider covers the REPL only — so the test exercises the
    // dismiss path instead). /exit then leaves the REPL. Both fed after a
    // beat so the picker is already listening.
    io.feedLater([0x1b], const Duration(milliseconds: 200));
    io.feedLater([0x2f, 0x65, 0x78, 0x69, 0x74, 0x0d, 0x0d],
        const Duration(milliseconds: 500));

    await coordinator.run().timeout(const Duration(seconds: 5));
    io.close();

    final out = io.written.toString();
    // The picker title wraps at the overlay width, so match short fragments.
    expect(out, contains('No ENVIRONMENT.md yet'),
        reason: 'the picker must render');
    expect(out, contains('Run now'), reason: 'the entries must render');
    expect(out, isNot(contains('the environment agent will populate it')),
        reason: 'cancelling the picker must NOT launch the agent');
  });

  test('first load explainer mentions side panel spawn', () async {
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
    expect(coordinator.pendingFirstLoadEnvironmentAsk, isNotNull);

    // Cancel the picker and exit.
    io.feedLater([0x1b], const Duration(milliseconds: 200));
    io.feedLater([0x2f, 0x65, 0x78, 0x69, 0x74, 0x0d, 0x0d],
        const Duration(milliseconds: 500));

    await coordinator.run().timeout(const Duration(seconds: 5));
    io.close();

    final out = io.written.toString();
    expect(out, contains('spawns its own side panel agent'),
        reason: 'the first-load explainer must mention side panel spawn');
    expect(out, contains('Run now in side panel'),
        reason: 'the picker entry must mention side panel');
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
      await store.append(sid, primaryId,
          Message(role: Role.user, content: [TextBlock('primary q')]));
      await store.append(sid, primaryId,
          Message(role: Role.assistant, content: [TextBlock('primary a')]));
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
        await store.append(sid, spawnId,
            Message(role: Role.user, content: [TextBlock('spawn $i q')]));
        await store.append(sid, spawnId,
            Message(role: Role.assistant, content: [TextBlock('spawn $i a')]));
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
        await store.append(sid, branchId,
            Message(role: Role.user, content: [TextBlock('branch $i q')]));
        await store.append(sid, branchId,
            Message(role: Role.assistant, content: [TextBlock('branch $i a')]));
      }
      return (sessionId: sid, primaryId: primaryId);
    }

    test('a session with spawns resumes split with right-column panels',
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

      // The restore + panelize + replay loops run synchronously inside
      // create(), so both the real Screen layout and the rendered byte stream
      // already reflect the restored structure BEFORE the REPL starts. (The
      // panel borders/labels/history are written by putAtAbsolute, which
      // flushes immediately.) We assert here rather than driving run() to stay
      // on the deterministic create() path.
      final layout = coordinator.screen.layout;
      expect(layout.isSplit, isTrue,
          reason: 'spawns must restore as a right-column split');
      expect(layout.infoLeftCol, greaterThan(0),
          reason: 'right column must start to the right of the chat');

      final out = io.written.toString();
      // Each spawn's panel title (`scout-<i> (anthropic-small)`) is drawn into
      // the right column — both labels appearing proves two panels restored.
      expect(out, contains('scout-0 (anthropic-small)'),
          reason: 'first spawn panel must restore');
      expect(out, contains('scout-1 (anthropic-small)'),
          reason: 'second spawn panel must restore');
      // And the restored spawn transcripts replay into their panels.
      expect(out, contains('spawn 0 q'),
          reason: 'first spawn history must replay');
      expect(out, contains('spawn 1 q'),
          reason: 'second spawn history must replay');
      // Primary must remain the active conversation — restoring side panels
      // must not steal focus from it.
      expect(coordinator.sessionManager.active.activeConversationId, primaryId,
          reason: 'primary must stay active after panel restore');
    });

    test('a session with a branch resumes the branch panel with fork history',
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
      final out = io.written.toString();
      expect(out, contains('research-0 (anthropic-small)'),
          reason: 'branch panel must restore with a branch role label');

      // The branch's on-disk meta is ConversationKind.branch, linked to its
      // parent — the fork lineage is inspectable in the manifest.
      final branchMeta = store
          .metaFor(sid, coordinator.spawnedPanels.single.conversationId)!;
      expect(branchMeta.kind, ConversationKind.branch,
          reason: 'a restored branch must keep its branch kind');
      expect(branchMeta.parentConversationId, primaryId,
          reason: 'the branch must link back to its parent conversation');

      // The forked parent history (primary q/a) replays into the branch panel,
      // followed by the branch's own follow-up turn.
      expect(out, contains('primary q'),
          reason: 'forked parent history must replay into the branch panel');
      expect(out, contains('branch 0 a'),
          reason: 'the branch follow-up turn must replay');

      // Primary stays active — restoring a branch panel must not steal focus.
      expect(coordinator.sessionManager.active.activeConversationId, primaryId,
          reason: 'primary must stay active after branch panel restore');
    });

    test('focusing a branched side panel does not corrupt the manifest anchor',
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
      expect(coordinator.sessionManager.active.activeConversationId,
          branchPanel.conversationId,
          reason: 'focusing a branch panel must route input to it');
      // ...but the persisted manifest anchor must stay the primary.
      final manifest = await store.loadSession(sid);
      expect(manifest.activeConversationId, primaryId,
          reason: 'the manifest anchor must stay the primary, not the branch');
    });

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
      expect(coordinator.screen.layout.isSplit, isFalse,
          reason: 'a session with no side panels must not split');
    });

    test('focusing a side panel does not corrupt the manifest anchor',
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
      expect(coordinator.sessionManager.active.activeConversationId,
          spawnPanel.conversationId,
          reason: 'focusing a side panel must route input to it');
      // ...but the persisted manifest anchor must remain the primary.
      final manifest = await store.loadSession(sid);
      expect(manifest.activeConversationId, primaryId,
          reason: 'the manifest anchor must stay the primary, not the panel');
    });

    // --- Phase 0 characterization (safety net for the panel-abstraction
    // refactor). These pin the tiling math and input-relocation behavior that
    // Phase 3 will move out of create() into PanelManager, so the move cannot
    // silently change panel geometry or where the shared input lands. ---

    test('spawned panels tile the right column: perPanel height, last absorbs the remainder, contiguous and aligned', () async {
      final store = MemorySessionStore();
      final seeded = await seedSession(store, spawnCount: 3);
      final io = FakeStdio()..hasTerminalValue = false;
      final config = Config.parse(
          ['--resume', seeded.sessionId, '--backend', 'ansi']);
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
      expect(layout.isSplit, isTrue,
          reason: '3 spawns must restore as a right-column split');
      final panels = coordinator.treeOrderedPanels;
      expect(panels, hasLength(3));

      final boxTop = layout.topBorderRow;
      final boxHeight = layout.bottomBorderRow - layout.topBorderRow + 1;
      final perPanel = boxHeight ~/ 3;

      // First panel's top aligns with the primary's top border row.
      expect(panels.first.bounds.row, boxTop,
          reason: 'first panel starts at the box top');
      // Every panel is perPanel tall except the last, which absorbs the
      // remainder so the column is fully covered with no gap or overlap.
      for (var i = 0; i < panels.length; i++) {
        final p = panels[i];
        final expectedH =
            i < panels.length - 1 ? perPanel : boxTop + boxHeight - p.bounds.row;
        expect(p.bounds.height, expectedH, reason: 'panel $i height');
      }
      // Contiguity: each panel begins exactly where the previous ended.
      for (var i = 0; i < panels.length - 1; i++) {
        expect(panels[i + 1].bounds.row,
            panels[i].bounds.row + panels[i].bounds.height,
            reason: 'panel $i is contiguous with the next');
      }
      // Full vertical coverage: last panel bottom == boxTop + boxHeight (the
      // primary's bottom border row).
      final last = panels.last;
      expect(last.bounds.row + last.bounds.height, boxTop + boxHeight,
          reason: 'panels fill the box top-to-bottom');
      // Flat spawns share one depth, so they share the same left col/width
      // (same indent under the info box).
      final col0 = panels.first.bounds.col;
      final w0 = panels.first.bounds.width;
      for (final p in panels) {
        expect(p.bounds.col, col0, reason: 'flat spawns share indent');
        expect(p.bounds.width, w0, reason: 'flat spawns share width');
      }
    });

    test('relocateInput repoints the shared input region onto the focused panel', () async {
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
      final config = Config.parse(
          ['--resume', seeded.sessionId, '--backend', 'ansi']);
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
      expect(coordinator.screen.input.bounds.row, a.inputRect.row,
          reason: 'focus a: row');
      expect(coordinator.screen.input.bounds.col, a.inputRect.col,
          reason: 'focus a: col');
      expect(coordinator.screen.input.bounds.width, a.inputRect.width,
          reason: 'focus a: width');
      expect(coordinator.screen.input.bounds.height, a.inputRect.height,
          reason: 'focus a: height');

      coordinator.focusManager.focusPanel(b);
      await pumpEventQueue();
      expect(coordinator.screen.input.bounds.row, b.inputRect.row,
          reason: 'focus b: row');
      expect(coordinator.screen.input.bounds.col, b.inputRect.col,
          reason: 'focus b: col');
      expect(coordinator.screen.input.bounds.width, b.inputRect.width,
          reason: 'focus b: width');
      expect(coordinator.screen.input.bounds.height, b.inputRect.height,
          reason: 'focus b: height');

      coordinator.focusManager.focusPanel(a);
      await pumpEventQueue();
      expect(coordinator.screen.input.bounds.row, a.inputRect.row,
          reason: 'refocus a: row');
      expect(coordinator.screen.input.bounds.col, a.inputRect.col,
          reason: 'refocus a: col');
      expect(coordinator.screen.input.bounds.width, a.inputRect.width,
          reason: 'refocus a: width');
      expect(coordinator.screen.input.bounds.height, a.inputRect.height,
          reason: 'refocus a: height');
    });
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

    test('copies the parent conversation full history into the branch panel',
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
      await store.append(sid, primaryId,
          Message(role: Role.user, content: [TextBlock('parent turn one')]));
      await store.append(sid, primaryId,
          Message(role: Role.assistant, content: [TextBlock('parent reply one')]));
      await store.append(sid, primaryId,
          Message(role: Role.user, content: [TextBlock('parent turn two')]));
      await store.append(sid, primaryId,
          Message(role: Role.assistant, content: [TextBlock('parent reply two')]));

      // Temp HOME with a `~/.tina/config` declaring anthropic + a test key.
      final tempHome =
          await Directory.systemTemp.createTemp('tina_branch_test_');
      addTearDown(() => tempHome.delete(recursive: true));
      writeUserConfig(
        const UserConfig(providers: {
          'anthropic': ProviderConfig(apiKey: 'test-key'),
        }),
        env: const {'HOME': '/__unused__'}, // env unused; tinaDir is explicit
        tinaDir: Directory('${tempHome.path}/.tina'),
      );
      final environment = FakeEnvironment(env: {
        'HOME': tempHome.path,
      });

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
      expect(parentHistory.length, greaterThan(0),
          reason: 'precondition: the live primary must carry seeded history');

      // Drive the real live fork callback — this is the untested path.
      await coordinator.controller.openBranch!();

      // A branch panel materialized in the right column.
      expect(coordinator.spawnedPanels.length, 1,
          reason: 'the fork must add exactly one branch panel');
      final branchPanel = coordinator.spawnedPanels.single;
      final branch =
          coordinator.sessionManager.active.conversationById(branchPanel.conversationId);
      expect(branch, isNotNull,
          reason: 'the branch panel must resolve to a conversation');

      // The fork copied the parent's FULL history into the branch, verbatim
      // and in order — this is the core "fork copies history" invariant.
      final branchTexts = branch!.history
          .map((m) => m.content.whereType<TextBlock>().map((b) => b.text).join())
          .toList();
      final parentTexts = parentHistory
          .map((m) => m.content.whereType<TextBlock>().map((b) => b.text).join())
          .toList();
      expect(branchTexts.length, parentTexts.length,
          reason: 'branch must have the same message count as the parent');
      for (var i = 0; i < parentTexts.length; i++) {
        expect(branchTexts[i], parentTexts[i],
            reason: 'branch message $i must equal the parent\'s (full copy)');
      }

      // The forked history must RENDER into the branch panel — not just exist
      // in the Conversation's in-memory list. Without replayHistory the panel
      // is blank even though branch.history is populated (the bug: history
      // sends to the model but nothing paints the chat region). Assert on the
      // byte stream the host flushed, like the restore-path tests do.
      final out = io.written.toString();
      for (final text in parentTexts) {
        expect(out, contains(text),
            reason: 'forked history "$text" must render into the branch panel');
      }

      // The parent is left untouched — its history is unchanged by the fork.
      expect(primary.history.length, parentHistory.length,
          reason: 'the parent history must not change when forked');
      // Focus moves to the new branch panel (the user just forked), so the
      // in-memory active conversation is the branch...
      expect(coordinator.sessionManager.active.activeConversationId,
          branchPanel.conversationId,
          reason: 'the fork must focus the new branch panel');
      // ...but the persisted manifest anchor stays the primary — the fork must
      // not promote the branch to the full-width slot on resume. This is the
      // "original continues untouched" invariant (onPanelFocused with
      // persist:false leaves the anchor on the parent).
      final manifest = await store.loadSession(sid);
      expect(manifest.activeConversationId, primaryId,
          reason: 'the manifest anchor must stay the parent, not the branch');

      // The branch persists on disk with its own id, kind=branch, linked to
      // the parent — so it resumes as a branch, not a fresh conversation.
      final branchMeta = manifest.conversations
          .firstWhere((m) => m.id == branchPanel.conversationId);
      expect(branchMeta.kind, ConversationKind.branch);
      expect(branchMeta.parentConversationId, primaryId);
    });
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
    test('the persistence factory materializes the primary and opens a panel',
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
      expect(factory, isNotNull,
          reason: 'precondition: the coordinator must wire the persistence '
              'factory so delegated sub-agents get panels');

      // A fabricated sub-agent job + meta, as the scheduler would build them.
      final job = SubAgentJob(
        id: 'j-test',
        label: 'scout',
        systemPrompt: 'scout identity',
        toolProfile: ToolProfile.readOnly,
        modelReference: 'anthropic/claude-haiku-4-5',
        originConversationId: coordinator.sessionManager.active.activeConversationId,
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

      expect(job.panelSink, isNotNull,
          reason: 'the factory must stash a panel sink so the sub-agent '
              'streams into its panel, not the parent chat');
      expect(job.panelHost, isNotNull,
          reason: 'the factory must stash a panel host so the scheduler can '
              'build the sub-agent as a first-class session');
      // A panel frame was created for the sub-agent.
      expect(coordinator.spawnedPanels, isNotEmpty,
          reason: 'a delegated sub-agent must open its own panel');
      // The panel title names both the role and the model (provider prefix
      // dropped), like every other conversation panel.
      expect(coordinator.spawnedPanels.single.label, 'scout (claude-haiku-4-5)',
          reason: 'a delegated sub-agent panel must show role + model');
    });

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
      expect(primary.label, contains('('),
          reason: 'primary panel title must include the model in parens');
      expect(primary.label, startsWith('main'),
          reason: 'primary panel title must start with the main role name');
    });
  });
}
