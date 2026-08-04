import 'package:tina/config/user_config.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina/tui/setup_overlay.dart';
import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import '../helpers/fake_stdio.dart';
import '../helpers/overlay_fixtures.dart';

/// Drives [runSetupOverlay] with canned [InputEvent]s against a Screen over
/// [FakeStdio] (no real terminal). Asserts the written config, not the pixels.
void main() {
  final tmp = TempTinaDir();
  final canned = CannedEvents();

  setUp(() {
    tmp.setUp();
    canned.clear();
  });
  tearDown(tmp.tearDown);

  Future<UserConfig?> run(Screen screen,
          {UserConfig? initial, ProviderRegistry? registryOverride}) =>
      runSetupOverlay(
        screen: screen,
        editor: LineEditor(screen: screen),
        registry: registryOverride ?? setupRegistry(),
        env: const {},
        tinaDir: tmp.dir,
        readEvent: canned.readEvent,
        initial: initial,
      );

  // -- Tests ----------------------------------------------------------------

  test('full flow: tree, heavy, light, confirm', () async {
    final screen = fakeScreen();
    // Tree step: expand alpha, type key, expand beta, type key.
    // Rows after alpha expanded: alpha/p, alpha/key, alpha/url,
    //   alpha/sep, alpha/a1, alpha/a2.
    // Then beta/provider, expand beta:
    //   beta/p, beta/key, beta/url, beta/sep, beta/b1.
    canned.events = [
      // --- Provider tree ---
      CharInput(' '), // check alpha
      ArrowKey(ArrowDirection.right), // expand alpha
      ArrowKey(ArrowDirection.down), // alpha/key
      CharInput('k'), CharInput('a'), // type "ka"
      ArrowKey(ArrowDirection.down), // alpha/url
      ArrowKey(ArrowDirection.down), // alpha/sep
      ArrowKey(ArrowDirection.down), // alpha/a1
      ArrowKey(ArrowDirection.down), // alpha/a2
      ArrowKey(ArrowDirection.down), // beta/provider
      CharInput(' '), // check beta
      ArrowKey(ArrowDirection.right), // expand beta
      ArrowKey(ArrowDirection.down), // beta/key
      CharInput('k'), CharInput('b'), // type "kb"
      // Enter from tree (any row) advances when _checked is non-empty.
      ControlKey(ControlCode.enter),
      // --- Heavy step: models [alpha/a1, alpha/a2, beta/b1] ---
      // Focus is at index 0 (alpha/a1) — Enter selects it.
      ControlKey(ControlCode.enter),
      // --- Light step: options [skip, alpha/a1, alpha/a2, beta/b1] ---
      ArrowKey(ArrowDirection.down), // skip → alpha/a1
      ArrowKey(ArrowDirection.down), // alpha/a1 → alpha/a2
      ArrowKey(ArrowDirection.down), // alpha/a2 → beta/b1
      ControlKey(ControlCode.enter), // select beta/b1
      // --- Theme step (first-run → no limits) ---
      ControlKey(ControlCode.enter), // theme (system) → confirm
      // --- Confirm ---
      ControlKey(ControlCode.enter), // write
    ];

    final cfg = await run(screen).timeout(overlayTimeout);

    expect(cfg, isNotNull);
    expect(cfg!.defaultProvider, 'alpha');
    expect(cfg.defaultModel, 'a1');
    expect(cfg.tiers, {'heavy': 'alpha/a1', 'light': 'beta/b1'});
    expect(cfg.providers['alpha']?.apiKey, 'ka');
    expect(cfg.providers['beta']?.apiKey, 'kb');
    // Round-trips through the file.
    final loaded = loadUserConfig(env: const {}, tinaDir: tmp.dir);
    expect(loaded.tiers, {'heavy': 'alpha/a1', 'light': 'beta/b1'});
    expect(loaded.providers['alpha']?.apiKey, 'ka');
    expect(loaded.providers['beta']?.apiKey, 'kb');
  });

  test('skip the light tier', () async {
    final screen = fakeScreen();
    canned.events = [
      CharInput(' '), // check alpha
      ArrowKey(ArrowDirection.right), // expand alpha
      ArrowKey(ArrowDirection.down), // alpha/key
      CharInput('k'), // type key
      // Enter from tree → heavy.
      ControlKey(ControlCode.enter),
      // Heavy: select alpha/a1.
      ControlKey(ControlCode.enter),
      // Light: focus is on "skip" (index 0), Enter skips it.
      ControlKey(ControlCode.enter),
      // Theme: system theme (default), Enter continues.
      ControlKey(ControlCode.enter),
      // Confirm (first-run → no limits).
      ControlKey(ControlCode.enter), // write
    ];
    final cfg = await run(screen).timeout(overlayTimeout);
    expect(cfg, isNotNull);
    expect(cfg!.tiers, {'heavy': 'alpha/a1'});
    expect(cfg.tiers.containsKey('light'), isFalse);
  });

  test('Esc at the providers step cancels (nothing written)', () async {
    final screen = fakeScreen();
    canned.events = [EscapeKey()];
    final cfg = await run(screen).timeout(overlayTimeout);
    expect(cfg, isNull);
    expect(userConfigFile(const {}, tinaDir: tmp.dir).existsSync(), isFalse);
  });

  test('Ctrl-C at the providers step cancels (sigint injects ctrlC)', () async {
    final screen = fakeScreen();
    canned.events = [ControlKey(ControlCode.ctrlC)];
    final cfg = await run(screen).timeout(overlayTimeout);
    expect(cfg, isNull);
  });

  test('pre-fill: Enter-through preserves the current config (keys retained)',
      () async {
    final screen = fakeScreen();
    final initial = UserConfig(
      defaultProvider: 'alpha',
      defaultModel: 'a1',
      tiers: {'heavy': 'alpha/a1', 'light': 'beta/b1'},
      providers: {
        'alpha': const ProviderConfig(apiKey: 'pre-key-alpha'),
        'beta': const ProviderConfig(apiKey: 'pre-key-beta'),
      },
    );
    // Providers (Enter) → heavy (Enter) → light (Enter) → theme (Enter) →
    // limits (Enter) → confirm (Enter). Pre-filled values auto-focus.
    canned.events = List.filled(6, ControlKey(ControlCode.enter));

    final cfg = await run(screen, initial: initial).timeout(overlayTimeout);

    expect(cfg, isNotNull);
    expect(cfg!.defaultProvider, 'alpha');
    expect(cfg.defaultModel, 'a1');
    expect(cfg.tiers, {'heavy': 'alpha/a1', 'light': 'beta/b1'});
    expect(cfg.providers['alpha']?.apiKey, 'pre-key-alpha');
    expect(cfg.providers['beta']?.apiKey, 'pre-key-beta');
    expect(cfg.limits, isNotNull);
    expect(cfg.limits!.maxGlobalTokens, 50000000);
  });

  test('reconfigure: the limits step edits a field and writes it', () async {
    final screen = fakeScreen();
    final initial = UserConfig(
      defaultProvider: 'alpha',
      defaultModel: 'a1',
      tiers: {'heavy': 'alpha/a1', 'light': 'beta/b1'},
      providers: {
        'alpha': const ProviderConfig(apiKey: 'ka'),
        'beta': const ProviderConfig(apiKey: 'kb'),
      },
      limits: const LimitsConfig(
        maxGlobalTokens: 11111,
        maxSubAgentTokens: 2222,
        requestsPerMinute: 0,
        maxTurnTokens: 333,
        maxSessionTokens: 444,
        maxRequestTokens: 555,
      ),
    );
    canned.events = [
      // Providers → heavy → light → theme → limits.
      ControlKey(ControlCode.enter),
      ControlKey(ControlCode.enter),
      ControlKey(ControlCode.enter),
      ControlKey(ControlCode.enter), // theme (system) → limits
      // Focus is on the first limit field (session tokens). Navigate down
      // to requests_per_minute (index 5).
      ArrowKey(ArrowDirection.down),
      ArrowKey(ArrowDirection.down),
      ArrowKey(ArrowDirection.down),
      ArrowKey(ArrowDirection.down),
      ArrowKey(ArrowDirection.down),
      // Type "30".
      CharInput('3'),
      CharInput('0'),
      ControlKey(ControlCode.enter), // limits → confirm
      ControlKey(ControlCode.enter), // confirm → write
    ];
    final cfg = await run(screen, initial: initial).timeout(overlayTimeout);

    expect(cfg, isNotNull);
    expect(cfg!.limits, isNotNull);
    expect(cfg.limits!.requestsPerMinute, 30, reason: 'the edited field');
    expect(cfg.limits!.maxGlobalTokens, 11111);
    expect(cfg.limits!.maxSubAgentTokens, 2222);
    expect(cfg.limits!.maxTurnTokens, 333);
    expect(cfg.limits!.maxSessionTokens, 444);
    expect(cfg.limits!.maxRequestTokens, 555);
  });

  test('first-run skips the limits step (no [limits] section written)',
      () async {
    final screen = fakeScreen();
    canned.events = [
      CharInput(' '), // check alpha
      ArrowKey(ArrowDirection.right), // expand alpha
      ArrowKey(ArrowDirection.down), // alpha/key
      CharInput('k'), // type key
      ControlKey(ControlCode.enter), // tree → heavy
      ControlKey(ControlCode.enter), // heavy → light (select alpha/a1)
      ControlKey(ControlCode.enter), // light skip → theme
      ControlKey(ControlCode.enter), // theme (system) → confirm
      ControlKey(ControlCode.enter), // confirm → write
    ];
    final cfg = await run(screen).timeout(overlayTimeout);
    expect(cfg, isNotNull);
    expect(cfg!.limits, isNull,
        reason: 'first-run (initial null) skips the limits step');
  });

  test('auth-optional provider is not prompted for a key', () async {
    final screen = fakeScreen();
    canned.events = [
      // Move to "local" (third provider, after alpha and beta).
      ArrowKey(ArrowDirection.down), // alpha/provider → beta/provider
      ArrowKey(ArrowDirection.down), // beta/provider → local/provider
      ArrowKey(ArrowDirection.down), // already at local, clamped
      CharInput(' '), // check local
      ArrowKey(ArrowDirection.right), // expand local (no key/URL rows)
      // Rows: local/p, local/sep, local/m1
      ArrowKey(ArrowDirection.down), // local/sep
      ArrowKey(ArrowDirection.down), // local/m1
      ControlKey(ControlCode.enter), // tree → heavy
      ControlKey(ControlCode.enter), // heavy → light (select local/m1)
      ControlKey(ControlCode.enter), // light skip → theme
      ControlKey(ControlCode.enter), // theme (system) → confirm
      ControlKey(ControlCode.enter), // confirm → write
    ];
    final cfg = await run(screen).timeout(overlayTimeout);
    expect(cfg, isNotNull);
    expect(cfg!.tiers, {'heavy': 'local/m1'});
    expect(cfg.providers, isEmpty);
  });

  // -- Theme variant tests ---------------------------------------------------

  test('selects dark theme variant', () async {
    final screen = fakeScreen();
    canned.events = [
      CharInput(' '), // check alpha
      ArrowKey(ArrowDirection.right), // expand alpha
      ArrowKey(ArrowDirection.down), // alpha/key
      CharInput('k'), // type key
      ControlKey(ControlCode.enter), // tree → heavy
      ControlKey(ControlCode.enter), // heavy → light (select alpha/a1)
      ControlKey(ControlCode.enter), // light skip → theme
      ArrowKey(ArrowDirection.down), // System theme → Dark theme
      ControlKey(ControlCode.enter), // select "Dark theme"
      ControlKey(ControlCode.enter), // confirm → write
    ];
    final cfg = await run(screen).timeout(overlayTimeout);
    expect(cfg, isNotNull);
    expect(cfg!.themeVariant, 'dark');
  });

  test('selects light theme variant', () async {
    final screen = fakeScreen();
    canned.events = [
      CharInput(' '), // check alpha
      ArrowKey(ArrowDirection.right), // expand alpha
      ArrowKey(ArrowDirection.down), // alpha/key
      CharInput('k'), // type key
      ControlKey(ControlCode.enter), // tree → heavy
      ControlKey(ControlCode.enter), // heavy → light (select alpha/a1)
      ControlKey(ControlCode.enter), // light skip → theme
      ArrowKey(ArrowDirection.down), // System theme → Dark theme
      ArrowKey(ArrowDirection.down), // Dark theme → Light theme
      ControlKey(ControlCode.enter), // select "Light theme"
      ControlKey(ControlCode.enter), // confirm → write
    ];
    final cfg = await run(screen).timeout(overlayTimeout);
    expect(cfg, isNotNull);
    expect(cfg!.themeVariant, 'light');
  });

  test('pre-fill preserves themeVariant from existing config', () async {
    final screen = fakeScreen();
    final initial = UserConfig(
      defaultProvider: 'alpha',
      defaultModel: 'a1',
      tiers: {'heavy': 'alpha/a1'},
      providers: {'alpha': const ProviderConfig(apiKey: 'ka')},
      themeVariant: 'dark',
    );
    // Providers → heavy → light → theme (pre-filled "Dark") → limits → confirm.
    canned.events = List.filled(6, ControlKey(ControlCode.enter));
    final cfg = await run(screen, initial: initial).timeout(overlayTimeout);
    expect(cfg, isNotNull);
    expect(cfg!.themeVariant, 'dark',
        reason: 'pre-filled dark should survive Enter-through');
  });

  test('Esc from theme goes back to light step', () async {
    final screen = fakeScreen();
    canned.events = [
      CharInput(' '), // check alpha
      ArrowKey(ArrowDirection.right), // expand alpha
      ArrowKey(ArrowDirection.down), // alpha/key
      CharInput('k'), // type key
      ControlKey(ControlCode.enter), // tree → heavy
      ControlKey(ControlCode.enter), // heavy → light (select a1)
      ControlKey(ControlCode.enter), // light skip → theme
      EscapeKey(), // back to light
      ControlKey(ControlCode.enter), // light skip → theme (again)
      ControlKey(ControlCode.enter), // theme (system) → confirm
      ControlKey(ControlCode.enter), // confirm → write
    ];
    final cfg = await run(screen).timeout(overlayTimeout);
    expect(cfg, isNotNull);
    expect(cfg!.themeVariant, isNull, reason: 'still system after back-nav');
  });

  test('shows catalog load warning when catalog.loadWarning is non-null',
      () async {
    // Warning appears on screen in the providers tree body.
    final io = FakeStdio()..hasTerminalValue = false;
    final layout = ScreenLayout.fromSize(80, 24, hasMenuBar: false);
    final screen = Screen(io: io, layout: layout);
    final reg = setupRegistry();
    reg.catalog = _WarningCatalog();

    canned.events = [
      EscapeKey()
    ]; // cancel immediately — warning rendered on first frame

    final cfg =
        await run(screen, registryOverride: reg).timeout(overlayTimeout);
    expect(cfg, isNull, reason: 'Escape cancels the overlay');

    final output = io.written.toString();
    expect(
      output,
      contains('⚠ Catalog proxy warning'),
    );
  });
}

/// A [ModelCatalog] that always returns a non-null [loadWarning] so tests
/// can verify the warning renders in the provider tree.
class _WarningCatalog implements ModelCatalog {
  @override
  List<ModelInfo> modelsFor(ProviderDescriptor desc) =>
      desc.models.values.toList();

  @override
  ModelInfo? findModel(ProviderDescriptor desc, String modelId) =>
      desc.models[modelId];

  @override
  bool hasAny(ProviderDescriptor desc) => desc.models.isNotEmpty;

  @override
  String? get loadWarning => 'Catalog proxy warning';

  @override
  void close() {}
}
