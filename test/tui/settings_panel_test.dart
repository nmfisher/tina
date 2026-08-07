import 'package:tina_engine/tina_engine.dart';
import 'package:tina/config/user_config.dart';
import 'package:tina/tui/settings_panel.dart';
import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import '../helpers/fake_stdio.dart';
import '../helpers/overlay_fixtures.dart';

/// A [Focusable] that records focus/blur/highlight calls and reports its focus
/// state, so we can assert the modal hands focus to/from the chat panel.
class RecordingFocusable implements Focusable {
  final List<String> calls = [];
  bool _hasFocus = false;
  final Rect bounds;
  RecordingFocusable(
      [this.bounds = const Rect(row: 0, col: 0, width: 5, height: 3)]) {}
  @override
  bool get hasFocus => _hasFocus;
  @override
  bool get canFocus => true;
  @override
  void focus() {
    _hasFocus = true;
    calls.add('focus');
  }

  @override
  void blur() {
    _hasFocus = false;
    calls.add('blur');
  }

  @override
  void highlight() => calls.add('highlight');
  @override
  void unhighlight() => calls.add('unhighlight');
  @override
  bool handleEvent(InputEvent event) => false;
}

/// Bundles a [FocusManager] with one focused [RecordingFocusable] and the
/// [LineEditor] it is attached to, so tests can assert on the focus hand-off.
class FocusSetup {
  final FocusManager manager;
  final RecordingFocusable panel;
  final LineEditor editor;
  FocusSetup(this.manager, this.panel, this.editor);
}

/// Build a [FocusManager] with one focused [RecordingFocusable] (the chat-panel
/// analog) and attach it to a freshly-constructed editor.
FocusSetup focusedEditor(Screen screen) {
  final panel = RecordingFocusable();
  final manager = FocusManager()..register(panel);
  manager.focusPanel(panel); // chat panel analog: focused + cyan
  final editor = LineEditor(screen: screen)..focusManager = manager;
  return FocusSetup(manager, panel, editor);
}

/// Drives [runSettingsPanel] (and its subpanels) with canned [InputEvent]s
/// against a Screen over [FakeStdio] (no real terminal). Asserts the written
/// config, not the pixels — same harness as `setup_overlay_test.dart`.
void main() {
  final tmp = TempTinaDir();
  final canned = CannedEvents();

  setUp(() {
    tmp.setUp('tina_settings_');
    canned.clear();
  });
  tearDown(tmp.tearDown);

  Future<UserConfig?> runIndex(Screen screen,
      {UserConfig? initial, ProviderRegistry? reg}) {
    // The index reloads each subpanel's baseline from disk, so pre-existing
    // config must be on disk for the panels to see + preserve it.
    if (initial != null) {
      writeUserConfig(initial, env: const {}, tinaDir: tmp.dir);
    }
    return runSettingsPanel(
      screen: screen,
      editor: LineEditor(screen: screen),
      registry: reg ?? setupRegistry(),
      env: const {},
      tinaDir: tmp.dir,
      readEvent: canned.readEvent,
    );
  }

  // -- index menu -----------------------------------------------------------

  test('Esc at the index closes settings, writing nothing', () async {
    final screen = fakeScreen();
    canned.events = [EscapeKey()];
    final wrote = await runIndex(screen).timeout(overlayTimeout);
    expect(wrote, isNull);
    expect(userConfigFile(const {}, tinaDir: tmp.dir).existsSync(), isFalse);
  });

  test('index: open providers, check a provider, save, return to index, close',
      () async {
    final screen = fakeScreen();
    // Index → "Providers & models" (index 0, Enter). In the providers panel:
    // check alpha (space), expand (→), focus key row (↓), type "ka", Enter to
    // save. Back at index, Esc to close.
    canned.events = [
      ControlKey(ControlCode.enter), // index → providers
      CharInput(' '), // check alpha
      ArrowKey(ArrowDirection.right), // expand alpha
      ArrowKey(ArrowDirection.down), // alpha/key
      CharInput('k'), CharInput('a'), // type "ka"
      ControlKey(ControlCode.enter), // providers → save
      EscapeKey(), // index → close
    ];
    final wrote = await runIndex(screen).timeout(overlayTimeout);
    expect(wrote, isNotNull);
    final loaded = loadUserConfig(env: const {}, tinaDir: tmp.dir);
    expect(loaded.providers['alpha']?.apiKey, 'ka');
  });

  // -- providers panel ------------------------------------------------------

  test('providers: cancel (Esc) writes nothing', () async {
    final screen = fakeScreen();
    canned.events = [
      ControlKey(ControlCode.enter), // index → providers
      CharInput(' '), // check alpha
      EscapeKey(), // cancel providers
      EscapeKey(), // close index
    ];
    final wrote = await runIndex(screen).timeout(overlayTimeout);
    expect(wrote, isNull);
    expect(userConfigFile(const {}, tinaDir: tmp.dir).existsSync(), isFalse);
  });

  test('providers: writes [providers] only — limits untouched', () async {
    final screen = fakeScreen();
    final initial = UserConfig(
      limits: const LimitsConfig(maxGlobalTokens: 12345),
    );
    canned.events = [
      ControlKey(ControlCode.enter), // index → providers
      CharInput(' '), // check alpha
      ArrowKey(ArrowDirection.right), // expand alpha
      ArrowKey(ArrowDirection.down), // alpha/key
      CharInput('k'), CharInput('a'), // type key
      ControlKey(ControlCode.enter), // save
      EscapeKey(), // close index
    ];
    await runIndex(screen, initial: initial).timeout(overlayTimeout);
    final loaded = loadUserConfig(env: const {}, tinaDir: tmp.dir);
    expect(loaded.providers['alpha']?.apiKey, 'ka');
    // Untouched slices preserved.
    expect(loaded.limits?.maxGlobalTokens, 12345);
  });

  // -- quota panel ----------------------------------------------------------

  test('quota: edits a limit and writes [limits] only', () async {
    final screen = fakeScreen();
    final initial = UserConfig(
      providers: const {'alpha': ProviderConfig(apiKey: 'ka')},
    );
    canned.events = [
      // Index: move to "Token quota" (index 1) then Enter.
      ArrowKey(ArrowDirection.down), // 0 → 1 (quota)
      ControlKey(ControlCode.enter), // open quota
      // Focus on first field (session tokens). Navigate down to
      // requests_per_minute (index 5).
      ArrowKey(ArrowDirection.down),
      ArrowKey(ArrowDirection.down),
      ArrowKey(ArrowDirection.down),
      ArrowKey(ArrowDirection.down),
      ArrowKey(ArrowDirection.down),
      CharInput('3'), CharInput('0'), // type "30"
      ControlKey(ControlCode.enter), // save quota
      EscapeKey(), // close index
    ];
    await runIndex(screen, initial: initial).timeout(overlayTimeout);
    final loaded = loadUserConfig(env: const {}, tinaDir: tmp.dir);
    expect(loaded.limits?.requestsPerMinute, 30);
    // Independent save: providers untouched.
    expect(loaded.providers['alpha']?.apiKey, 'ka');
  });

  // -- theme panel ----------------------------------------------------------

  test('theme: selecting dark writes [theme] variant', () async {
    final screen = fakeScreen();
    canned.events = [
      // Index: move to "Theme" (index 2) then Enter.
      ArrowKey(ArrowDirection.down), // 0 → 1
      ArrowKey(ArrowDirection.down), // 1 → 2 (theme)
      ControlKey(ControlCode.enter), // open theme
      // Picker: [System, Dark, Light]; pick Dark (down, enter).
      ArrowKey(ArrowDirection.down), // System → Dark
      ControlKey(ControlCode.enter), // select dark
      EscapeKey(), // close index
    ];
    await runIndex(screen).timeout(overlayTimeout);
    final loaded = loadUserConfig(env: const {}, tinaDir: tmp.dir);
    expect(loaded.themeVariant, 'dark');
  });

  // -- unchanged detection --------------------------------------------------

  test('quota: opening and saving with no edit returns null (unchanged)',
      () async {
    final screen = fakeScreen();
    // Seed the exact defaults the quota panel displays, so saving with no edit
    // is a no-op. (An all-null LimitsConfig would bake in those defaults and
    // register as a change.)
    final initial = UserConfig(
      limits: const LimitsConfig(
        maxSessionTokens: 10000000,
        maxTurnTokens: 1000000,
        maxRequestTokens: 200000,
        maxGlobalTokens: 50000000,
        maxSubAgentTokens: 2000000,
        requestsPerMinute: 0,
      ),
    );
    canned.events = [
      ArrowKey(ArrowDirection.down), // index 1 (quota)
      ControlKey(ControlCode.enter), // open quota
      ControlKey(ControlCode.enter), // save (no edit)
      EscapeKey(), // close index
    ];
    final wrote =
        await runIndex(screen, initial: initial).timeout(overlayTimeout);
    expect(wrote, isNull);
  });

  // -- hop between panels ---------------------------------------------------

  test('hop: edit quota then edit theme — both persist independently',
      () async {
    final screen = fakeScreen();
    canned.events = [
      // Open quota (index 1).
      ArrowKey(ArrowDirection.down),
      ControlKey(ControlCode.enter),
      // Edit requests_per_minute → "7".
      ArrowKey(ArrowDirection.down),
      ArrowKey(ArrowDirection.down),
      ArrowKey(ArrowDirection.down),
      ArrowKey(ArrowDirection.down),
      ArrowKey(ArrowDirection.down),
      CharInput('7'),
      ControlKey(ControlCode.enter), // save quota
      // Back at index (focus reset to 0): open theme (index 2).
      ArrowKey(ArrowDirection.down), // 0 → 1
      ArrowKey(ArrowDirection.down), // 1 → 2 (theme)
      ControlKey(ControlCode.enter),
      // Pick Light (down, down, enter).
      ArrowKey(ArrowDirection.down),
      ArrowKey(ArrowDirection.down),
      ControlKey(ControlCode.enter),
      EscapeKey(), // close index
    ];
    await runIndex(screen).timeout(overlayTimeout);
    final loaded = loadUserConfig(env: const {}, tinaDir: tmp.dir);
    expect(loaded.limits?.requestsPerMinute, 7);
    expect(loaded.themeVariant, 'light');
  });

  // -- active-surface blue highlight ------------------------------------------

  group('active modal is the single blue panel', () {
    /// A Screen whose color output we can force on, so the cyan focus SGR code
    /// reaches the fake stdio and is assertable.
    Screen coloredScreen(FakeStdio io) {
      final layout = ScreenLayout.fromSize(80, 24, hasMenuBar: false);
      return Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
    }

    test('the modal paints its frame in the focus (cyan) color', () async {
      final io = FakeStdio()..hasTerminalValue = false;
      final screen = coloredScreen(io);
      // Open settings and immediately cancel — the index frame must be cyan.
      final setup = focusedEditor(screen);
      canned.events = [EscapeKey()];
      final wrote = await runSettingsPanel(
        screen: screen,
        editor: setup.editor,
        registry: setupRegistry(),
        env: const {},
        tinaDir: tmp.dir,
        readEvent: canned.readEvent,
      ).timeout(overlayTimeout);
      expect(wrote, isNull);
      final output = io.written.toString();
      // The title corners carry the focus SGR (cyan) while the modal is shown.
      expect(output.contains('\x1b[36m┌'), isTrue,
          reason: 'modal frame should be cyan while active');
    });

    test(
        'the focused chat panel blurs while the modal is open, refocuses on close',
        () async {
      final screen = coloredScreen(FakeStdio()..hasTerminalValue = false);
      final setup = focusedEditor(screen);
      // Precondition: a panel is focused (cyan) before settings opens.
      expect(setup.panel.hasFocus, isTrue);
      setup.panel.calls.clear(); // only watch the modal's hand-off, not setup
      canned.events = [EscapeKey()];
      await runSettingsPanel(
        screen: screen,
        editor: setup.editor,
        registry: setupRegistry(),
        env: const {},
        tinaDir: tmp.dir,
        readEvent: canned.readEvent,
      ).timeout(overlayTimeout);
      // The modal blurred the chat panel on open and refocused it on close.
      expect(setup.panel.calls, containsAll(['blur', 'focus']));
      // blur precedes focus: exactly one blue panel at a time.
      expect(setup.panel.calls.indexOf('blur'),
          lessThan(setup.panel.calls.indexOf('focus')));
      expect(setup.panel.hasFocus, isTrue);
    });
  });
}
