
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:tina/composition/models_dev_seed.dart';
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


  test('providers: the search field filters providers live', () async {
    final screen = fakeScreen();
    // Row 0 is the /search field (initial focus starts on the first
    // provider row below it). Typing 'be' from the search row narrows the
    // list to beta; the next ↓+space therefore checks BETA, not alpha.
    canned.events = [
      ControlKey(ControlCode.enter), // index → providers
      ArrowKey(ArrowDirection.up), // onto the /search row
      CharInput('b'),
      CharInput('e'), // filter → beta only
      ArrowKey(ArrowDirection.down), // first (only) provider: beta
      CharInput(' '), // check beta
      ControlKey(ControlCode.enter), // providers → save
      EscapeKey(), // index → close
    ];
    final wrote = await runIndex(screen).timeout(overlayTimeout);
    expect(wrote, isNotNull);
    final loaded = loadUserConfig(env: const {}, tinaDir: tmp.dir);
    expect(loaded.providers['beta']?.apiKey, isNull,
        reason: 'checked with no key typed — block carries curation only');
    expect(loaded.providers.containsKey('alpha'), isFalse,
        reason: 'alpha was filtered out and never checked');
  });

  test('providers: typing a key auto-selects the provider', () async {
    final screen = fakeScreen();
    // No initial config: alpha is unchecked. Expand, focus the key row, and
    // type — the provider must check ITSELF (no separate space toggle), and
    // the save must write the credential.
    canned.events = [
      ControlKey(ControlCode.enter), // index → providers
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

  test('providers: a never-curated provider saves models explicitly disabled',
      () async {
    final screen = fakeScreen();
    // Initial config has alpha with a key but NO disabled_models: under the
    // disable-by-default flip, both models start unchecked, and saving
    // without touching them writes the explicit all-disabled state.
    final initial = UserConfig(providers: {
      'alpha': ProviderConfig(apiKey: 'ka'),
    });
    canned.events = [
      ControlKey(ControlCode.enter), // index → providers
      ControlKey(ControlCode.enter), // providers → save
      EscapeKey(), // index → close
    ];
    final wrote =
        await runIndex(screen, initial: initial).timeout(overlayTimeout);
    expect(wrote, isNotNull);
    final loaded = loadUserConfig(env: const {}, tinaDir: tmp.dir);
    final disabled = loaded.providers['alpha']?.disabledModels;
    expect(disabled, isNotNull, reason: 'the save must be explicit, not null');
    expect(disabled, {'a1', 'a2'});
  });

  test('providers: checking one model enables exactly that model', () async {
    final screen = fakeScreen();
    // alpha/key → alpha/url → separator → alpha/a1; space checks a1; save.
    // The written set is the complement: only a2 stays disabled.
    final initial = UserConfig(providers: {
      'alpha': ProviderConfig(apiKey: 'ka'),
    });
    canned.events = [
      ControlKey(ControlCode.enter), // index → providers
      ArrowKey(ArrowDirection.right), // expand alpha
      ArrowKey(ArrowDirection.down), // alpha/key
      ArrowKey(ArrowDirection.down), // alpha/url
      ArrowKey(ArrowDirection.down), // separator
      ArrowKey(ArrowDirection.down), // alpha/a1
      CharInput(' '), // enable a1
      ControlKey(ControlCode.enter), // providers → save
      EscapeKey(), // index → close
    ];
    final wrote =
        await runIndex(screen, initial: initial).timeout(overlayTimeout);
    expect(wrote, isNotNull);
    final loaded = loadUserConfig(env: const {}, tinaDir: tmp.dir);
    expect(loaded.providers['alpha']?.disabledModels, {'a2'});
  });

  test('providers: ＋add model declares a custom id and enables it', () async {
    final screen = fakeScreen();
    // alpha keyed (never curated → a1/a2 disabled by default). Expand, walk
    // down to ＋add model, Enter, paste "glm-5.2|GLM 5.2", Enter commits.
    // Rows grew by one, so focus now sits on the new model row; ↑ then Enter
    // saves from a model row.
    final initial = UserConfig(providers: {
      'alpha': ProviderConfig(apiKey: 'ka'),
    });
    canned.events = [
      ControlKey(ControlCode.enter), // index → providers
      ArrowKey(ArrowDirection.right), // expand alpha
      ArrowKey(ArrowDirection.down), // alpha/key
      ArrowKey(ArrowDirection.down), // alpha/url
      ArrowKey(ArrowDirection.down), // separator
      ArrowKey(ArrowDirection.down), // alpha/a1
      ArrowKey(ArrowDirection.down), // alpha/a2
      ArrowKey(ArrowDirection.down), // ＋add model
      ControlKey(ControlCode.enter), // start text entry
      PasteInput('glm-5.2|GLM 5.2'),
      ControlKey(ControlCode.enter), // commit
      ArrowKey(ArrowDirection.up), // move off the add row
      ControlKey(ControlCode.enter), // providers → save
      EscapeKey(), // index → close
    ];
    final wrote =
        await runIndex(screen, initial: initial).timeout(overlayTimeout);
    expect(wrote, isNotNull);
    final loaded = loadUserConfig(env: const {}, tinaDir: tmp.dir);
    final alpha = loaded.providers['alpha'];
    final added = alpha?.models?.where((m) => m.id == 'glm-5.2').toList();
    expect(added, hasLength(1), reason: 'the custom id must be declared');
    expect(added!.single.name, 'GLM 5.2');
    // Declaring enabled the new model; the untouched registry models stay
    // explicitly disabled.
    expect(alpha?.disabledModels, {'a1', 'a2'});
  });

  test('providers: a provider absent from config starts all-models-disabled',
      () async {
    final screen = fakeScreen();
    // Registry provider `alpha` has NO config block at all (env-credentialed
    // style). Its model rows must start ☐ disabled: checking a1 and saving
    // writes the block with exactly a2 left disabled. The regression this
    // pins: absent providers used to render all-enabled, so a space toggled
    // a1 OFF and the write came out inverted.
    canned.events = [
      ControlKey(ControlCode.enter), // index → providers
      CharInput(' '), // check alpha (was unchecked: not in config)
      ArrowKey(ArrowDirection.right), // expand alpha
      ArrowKey(ArrowDirection.down), // alpha/key
      ArrowKey(ArrowDirection.down), // alpha/url
      ArrowKey(ArrowDirection.down), // separator
      ArrowKey(ArrowDirection.down), // alpha/a1
      CharInput(' '), // enable a1 (it started disabled)
      ControlKey(ControlCode.enter), // providers → save
      EscapeKey(), // index → close
    ];
    final wrote = await runIndex(screen).timeout(overlayTimeout);
    expect(wrote, isNotNull);
    final loaded = loadUserConfig(env: const {}, tinaDir: tmp.dir);
    final alpha = loaded.providers['alpha'];
    expect(alpha?.apiKey, isNull,
        reason: 'the provider had no key; only curation is written');
    expect(alpha?.disabledModels, {'a2'},
        reason: 'a1 was explicitly enabled; a2 stays disabled');
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

  // -- writeUserConfigPatch: the `/model` "global default" write -------------

  group('writeUserConfigPatch', () {
    /// A config exercising every slice the old hand-built literal dropped —
    /// the regression the copyWith switch prevents.
    UserConfig fullConfig() => const UserConfig(
      defaultProvider: 'anthropic',
      defaultModel: 'claude-sonnet-4-6',
      defaultWorkflow: 'house.dot',
      providers: {'alpha': ProviderConfig(apiKey: 'ka')},
      themeVariant: 'dark',
      trustDefault: 'always',
      environmentAutoPopulate: 'always',
      environmentModel: 'glm/glm-5.2',
      mouseWheel: true,
      regions: RegionsConfig(model: 'glm/glm-5.2'),
      permissions: PermissionsConfig(mode: 'allow_edits', model: 'glm/glm-5.2'),
    );

    test('defaultRef writes [default] and preserves every other slice', () {
      writeUserConfig(fullConfig(), env: const {}, tinaDir: tmp.dir);
      final wrote = writeUserConfigPatch(
        env: const {},
        tinaDir: tmp.dir,
        defaultRef: 'glm/glm-5.2',
      );
      expect(wrote, isNotNull);
      final loaded = loadUserConfig(env: const {}, tinaDir: tmp.dir);
      expect(loaded.defaultProvider, 'glm');
      expect(loaded.defaultModel, 'glm-5.2');
      // Slices this call did not name survive the read-modify-write.
      expect(loaded.defaultWorkflow, 'house.dot');
      expect(loaded.providers['alpha']?.apiKey, 'ka');
      expect(loaded.themeVariant, 'dark');
      expect(loaded.trustDefault, 'always');
      expect(loaded.environmentAutoPopulate, 'always');
      expect(loaded.environmentModel, 'glm/glm-5.2');
      expect(loaded.mouseWheel, isTrue);
      expect(loaded.regions?.model, 'glm/glm-5.2');
      expect(loaded.permissions?.mode, 'allow_edits');
    });

    test('splits on the FIRST slash, so a model id may contain slashes', () {
      final wrote = writeUserConfigPatch(
        env: const {},
        tinaDir: tmp.dir,
        defaultRef: 'openrouter/x-ai/grok-4',
      );
      expect(wrote, isNotNull);
      final loaded = loadUserConfig(env: const {}, tinaDir: tmp.dir);
      expect(loaded.defaultProvider, 'openrouter');
      expect(loaded.defaultModel, 'x-ai/grok-4');
    });

    test('re-picking the stored default writes nothing', () {
      writeUserConfig(fullConfig(), env: const {}, tinaDir: tmp.dir);
      final wrote = writeUserConfigPatch(
        env: const {},
        tinaDir: tmp.dir,
        defaultRef: 'anthropic/claude-sonnet-4-6',
      );
      expect(wrote, isNull);
    });

    test('a slashless defaultRef leaves the stored pair alone', () {
      writeUserConfig(fullConfig(), env: const {}, tinaDir: tmp.dir);
      // No slash → not a ref; the slice is skipped, so nothing changed → null.
      final wrote = writeUserConfigPatch(
        env: const {},
        tinaDir: tmp.dir,
        defaultRef: 'grok-4',
      );
      expect(wrote, isNull);
      final loaded = loadUserConfig(env: const {}, tinaDir: tmp.dir);
      expect(loaded.defaultProvider, 'anthropic');
      expect(loaded.defaultModel, 'claude-sonnet-4-6');
    });
  });

  // -- models.dev discovery -------------------------------------------------

  group('models.dev discovery', () {
    // A provider registered from the discovery feed: no `[providers.<id>]`
    // block yet, so it renders unchecked with every model disabled.
    ProviderRegistry seededRegistry() {
      final r = ProviderRegistry(env: const {});
      registerModelsDevProviders(
        registry: r,
        env: const {'MOONSHOT_API_KEY': 'sk-test'},
        providers: {
          'moonshotai': ModelsDevProviderInfo(
            key: 'moonshotai',
            name: 'Moonshot AI',
            envVars: const ['MOONSHOT_API_KEY'],
            npm: '@ai-sdk/openai-compatible',
            apiBase: 'https://api.moonshot.ai/v1',
            models: const {
              'kimi-k2': ModelInfo(
                id: 'kimi-k2',
                name: 'Kimi K2',
                contextWindow: 262144,
                maxOutput: 16384,
              ),
              'kimi-k1': ModelInfo(
                id: 'kimi-k1',
                name: 'Kimi K1',
                contextWindow: 131072,
                maxOutput: 8192,
              ),
            },
          ),
        },
      );
      return r;
    }

    /// A [Screen] whose [FakeStdio] the test can inspect (`fakeScreen` hides it).
    (Screen, FakeStdio) screenWithIo() {
      final io = FakeStdio()..hasTerminalValue = false;
      return (
        Screen(io: io, layout: ScreenLayout.fromSize(80, 24, hasMenuBar: false)),
        io,
      );
    }

    /// A discovery catalog seeded from a cache file aged [age].
    Future<ModelsDevProviderCatalog> catalogWithCache(
      Duration age, {
      http.Client? client,
      bool failRefresh = false,
    }) async {
      final dir = Directory(p.join(tmp.dir.path, '.tina', 'cache'))
        ..createSync(recursive: true);
      final f = File(p.join(dir.path, 'models.dev.providers.json'))
        ..writeAsStringSync('{}');
      f.setLastModifiedSync(DateTime.now().subtract(age));

      final catalog = ModelsDevProviderCatalog(
        env: {'HOME': tmp.dir.path},
        client: client ?? _CrashClient(),
      );
      await catalog.loadFromCache();
      if (failRefresh) await catalog.refresh();
      return catalog;
    }

    test('a seeded provider renders and curating a model writes its block',
        () async {
      final (screen, io) = screenWithIo();
      canned.events = [
        ControlKey(ControlCode.enter), // index → providers
        CharInput(' '), // check moonshotai (was unchecked: no config block)
        ArrowKey(ArrowDirection.right), // expand
        ArrowKey(ArrowDirection.down), // key row
        ArrowKey(ArrowDirection.down), // base URL row
        ArrowKey(ArrowDirection.down), // models separator
        ArrowKey(ArrowDirection.down), // kimi-k2 (disabled by default)
        CharInput(' '), // enable kimi-k2
        ControlKey(ControlCode.enter), // providers → save
        EscapeKey(), // index → close
      ];
      final wrote =
          await runIndex(screen, reg: seededRegistry()).timeout(overlayTimeout);
      expect(wrote, isNotNull);
      expect(io.written.toString(), contains('Moonshot AI'),
          reason: 'the discovered provider gets a settings row');

      final loaded = loadUserConfig(env: const {}, tinaDir: tmp.dir);
      final md = loaded.providers['moonshotai'];
      expect(md, isNotNull, reason: 'curating writes the config block');
      expect(md?.apiKey, isNull, reason: 'the key came from the environment');
      expect(md?.disabledModels, {'kimi-k1'},
          reason: 'kimi-k2 enabled, kimi-k1 left disabled');
    });

    test('the freshness row reports the cache age', () async {
      final (screen, io) = screenWithIo();
      final reg = seededRegistry()
        ..providerCatalog = await catalogWithCache(const Duration(days: 3));
      canned.events = [
        ControlKey(ControlCode.enter), // index → providers
        EscapeKey(), // providers → cancel
        EscapeKey(), // index → close
      ];
      await runIndex(screen, reg: reg).timeout(overlayTimeout);

      expect(
        io.written.toString(),
        contains('models.dev providers: cached 3d ago — up to date'),
      );
    });

    test('a failed refresh is reported and pending', () async {
      final (screen, io) = screenWithIo();
      final reg = seededRegistry()
        ..providerCatalog =
            await catalogWithCache(const Duration(hours: 2), failRefresh: true);
      canned.events = [
        ControlKey(ControlCode.enter), // index → providers
        EscapeKey(), // providers → cancel
        EscapeKey(), // index → close
      ];
      await runIndex(screen, reg: reg).timeout(overlayTimeout);

      final out = io.written.toString();
      expect(out, contains('models.dev providers: cached 2h ago — refresh failed'));
      expect(out, contains('⚠ models.dev provider list unavailable'));
    });

    test('a refresh in flight renders as pending, not up to date', () async {
      final (screen, io) = screenWithIo();
      final catalog = await catalogWithCache(
        const Duration(hours: 1),
        client: _HangClient(),
      );
      final reg = seededRegistry()..providerCatalog = catalog;
      // Never completes: the flag the row reads is the only observable.
      unawaited(catalog.refresh());

      canned.events = [
        ControlKey(ControlCode.enter), // index → providers
        EscapeKey(), // providers → cancel
        EscapeKey(), // index → close
      ];
      await runIndex(screen, reg: reg).timeout(overlayTimeout);

      expect(
        io.written.toString(),
        contains('models.dev providers: cached 1h ago — pending (next launch)'),
      );
    });

    test('no discovery catalog renders no freshness row', () async {
      final (screen, io) = screenWithIo();
      canned.events = [
        ControlKey(ControlCode.enter), // index → providers
        EscapeKey(), // providers → cancel
        EscapeKey(), // index → close
      ];
      await runIndex(screen, reg: setupRegistry()).timeout(overlayTimeout);

      expect(io.written.toString(), isNot(contains('models.dev providers:')));
    });
  });
}

/// An HTTP client whose requests fail — for the refresh-failure row.
class _CrashClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw http.ClientException('connection refused');
  }
}

/// An HTTP client whose request never completes — a refresh in flight.
class _HangClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
}
