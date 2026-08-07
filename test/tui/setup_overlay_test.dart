import 'dart:io';

import 'package:tina/config/user_config.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina/tui/setup_overlay.dart';
import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import '../helpers/fake_stdio.dart';
import '../helpers/overlay_fixtures.dart';

/// Drives [runSetupOverlay] with canned [InputEvent]s against a Screen over
/// [FakeStdio] (no real terminal). Asserts the written config, not the pixels.
///
/// Flow: providers (tree) → default model → theme → limits (/settings only)
/// → confirm.
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

  test('full flow: tree, default model, theme, confirm', () async {
    final screen = fakeScreen();
    // Tree step: expand alpha, type key, expand beta, type key.
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
      // --- Default-model step: models [alpha/a1, alpha/a2, beta/b1] ---
      // Focus is at index 0 (alpha/a1) — Enter selects it.
      ControlKey(ControlCode.enter),
      // --- Theme step (first-run → no limits) ---
      ControlKey(ControlCode.enter), // theme (system) → confirm
      // --- Confirm ---
      ControlKey(ControlCode.enter), // write
    ];

    final cfg = await run(screen).timeout(overlayTimeout);

    expect(cfg, isNotNull);
    expect(cfg!.defaultProvider, 'alpha');
    expect(cfg.defaultModel, 'a1');
    expect(cfg.providers['alpha']?.apiKey, 'ka');
    expect(cfg.providers['beta']?.apiKey, 'kb');
    // Round-trips through the file.
    final loaded = loadUserConfig(env: const {}, tinaDir: tmp.dir);
    expect(loaded.defaultProvider, 'alpha');
    expect(loaded.defaultModel, 'a1');
    expect(loaded.providers['alpha']?.apiKey, 'ka');
    expect(loaded.providers['beta']?.apiKey, 'kb');
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
      providers: {
        'alpha': const ProviderConfig(apiKey: 'pre-key-alpha'),
        'beta': const ProviderConfig(apiKey: 'pre-key-beta'),
      },
    );
    // Providers (Enter) → default model (Enter) → theme (Enter) → limits
    // (Enter) → confirm (Enter). Pre-filled values auto-focus.
    canned.events = List.filled(5, ControlKey(ControlCode.enter));

    final cfg = await run(screen, initial: initial).timeout(overlayTimeout);

    expect(cfg, isNotNull);
    expect(cfg!.defaultProvider, 'alpha');
    expect(cfg.defaultModel, 'a1');
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
      // Providers → default model → theme → limits.
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
      ControlKey(ControlCode.enter), // tree → default model
      ControlKey(ControlCode.enter), // default model (alpha/a1) → theme
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
      ControlKey(ControlCode.enter), // tree → default model
      ControlKey(ControlCode.enter), // default model (local/m1) → theme
      ControlKey(ControlCode.enter), // theme (system) → confirm
      ControlKey(ControlCode.enter), // confirm → write
    ];
    final cfg = await run(screen).timeout(overlayTimeout);
    expect(cfg, isNotNull);
    expect(cfg!.defaultProvider, 'local');
    expect(cfg.defaultModel, 'm1');
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
      ControlKey(ControlCode.enter), // tree → default model
      ControlKey(ControlCode.enter), // default model (alpha/a1) → theme
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
      ControlKey(ControlCode.enter), // tree → default model
      ControlKey(ControlCode.enter), // default model (alpha/a1) → theme
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
      providers: {'alpha': const ProviderConfig(apiKey: 'ka')},
      themeVariant: 'dark',
    );
    // Providers → default model → theme (pre-filled "Dark") → limits → confirm.
    canned.events = List.filled(5, ControlKey(ControlCode.enter));
    final cfg = await run(screen, initial: initial).timeout(overlayTimeout);
    expect(cfg, isNotNull);
    expect(cfg!.themeVariant, 'dark',
        reason: 'pre-filled dark should survive Enter-through');
  });

  test('Esc from theme goes back to the default-model step', () async {
    final screen = fakeScreen();
    canned.events = [
      CharInput(' '), // check alpha
      ArrowKey(ArrowDirection.right), // expand alpha
      ArrowKey(ArrowDirection.down), // alpha/key
      CharInput('k'), // type key
      ControlKey(ControlCode.enter), // tree → default model
      ControlKey(ControlCode.enter), // default model → theme
      EscapeKey(), // back to default model
      ControlKey(ControlCode.enter), // default model → theme (again)
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
  test('read-only config: write failure is surfaced in-modal, not thrown',
      () async {
    // A read-only config file (as the sandbox's :ro mount produces) makes the
    // confirm-time write fail. The overlay must stay open, show the error, and
    // let the user back out — not throw an unhandled FileSystemException.
    final io = FakeStdio()..hasTerminalValue = false;
    final layout = ScreenLayout.fromSize(80, 24, hasMenuBar: false);
    final screen = Screen(io: io, layout: layout);

    final cfgFile = File('${tmp.dir.path}/config');
    cfgFile.writeAsStringSync('version = 1\n');
    Process.runSync('chmod', ['444', cfgFile.path]);
    addTearDown(() => Process.runSync('chmod', ['644', cfgFile.path]));

    canned.events = [
      CharInput(' '), // check alpha
      ArrowKey(ArrowDirection.right), // expand alpha
      ArrowKey(ArrowDirection.down), // alpha/key
      CharInput('k'), // type key
      ControlKey(ControlCode.enter), // tree → default model
      ControlKey(ControlCode.enter), // default model → theme
      ControlKey(ControlCode.enter), // theme (system) → confirm
      ControlKey(ControlCode.enter), // confirm → write FAILS, stays open
      EscapeKey(), // confirm → theme
      EscapeKey(), // theme → default model
      EscapeKey(), // default model → providers
      EscapeKey(), // providers → cancel
    ];

    final cfg = await run(screen).timeout(overlayTimeout);

    expect(cfg, isNull, reason: 'cancelled after the write failed');
    expect(io.written.toString(), contains('Could not write'),
        reason: 'the write error is shown in the modal');
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
