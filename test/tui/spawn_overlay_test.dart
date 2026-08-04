import 'package:tina/tui/spawn_overlay.dart';
import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import '../helpers/overlay_fixtures.dart';

/// Drives [runSpawnOverlay] with canned [InputEvent]s against a Screen over
/// [FakeStdio] (no real terminal). Asserts the returned model reference.
///
/// With `configuredProviders: {'alpha', 'beta'}` the flat model list is:
///   ["alpha/a1", "alpha/a2", "beta/b1"]
void main() {
  final canned = CannedEvents();

  setUp(canned.clear);

  Future<String?> run(Screen screen,
          {Set<String> configured = const {'alpha', 'beta'},
          Set<String> disabled = const {},
          List<String> recentlyUsed = const []}) =>
      runSpawnOverlay(
        screen: screen,
        editor: LineEditor(screen: screen),
        registry: spawnRegistry(),
        configuredProviders: configured,
        disabledModelRefs: disabled,
        recentlyUsed: recentlyUsed,
        readEvent: canned.readEvent,
      );

  // -- Tests ----------------------------------------------------------------

  test('select first model with Enter at focus 0', () async {
    final screen = fakeScreen();
    canned.events = [
      ControlKey(ControlCode.enter), // select alpha/a1 (focus 0)
    ];
    final result = await run(screen).timeout(overlayTimeout);
    expect(result, 'alpha/a1');
  });

  test('navigate down once and select alpha/a2', () async {
    final screen = fakeScreen();
    canned.events = [
      ArrowKey(ArrowDirection.down), // alpha/a1 → alpha/a2
      ControlKey(ControlCode.enter), // select alpha/a2
    ];
    final result = await run(screen).timeout(overlayTimeout);
    expect(result, 'alpha/a2');
  });

  test('navigate to beta/b1 and select', () async {
    final screen = fakeScreen();
    canned.events = [
      ArrowKey(ArrowDirection.down), // alpha/a1 → alpha/a2
      ArrowKey(ArrowDirection.down), // alpha/a2 → beta/b1
      ControlKey(ControlCode.enter), // select beta/b1
    ];
    final result = await run(screen).timeout(overlayTimeout);
    expect(result, 'beta/b1');
  });

  test('navigate to beta/b1 with all providers configured', () async {
    final screen = fakeScreen();
    // All three providers configured → list is alpha/a1, alpha/a2, beta/b1,
    // gamma/g1, gamma/g2, gamma/g3.
    canned.events = [
      ArrowKey(ArrowDirection.down), // alpha/a1 → alpha/a2
      ArrowKey(ArrowDirection.down), // alpha/a2 → beta/b1
      ControlKey(ControlCode.enter), // select beta/b1
    ];
    final result = await run(screen, configured: {'alpha', 'beta', 'gamma'})
        .timeout(overlayTimeout);
    expect(result, 'beta/b1');
  });

  test('Esc at initial screen cancels (returns null)', () async {
    final screen = fakeScreen();
    canned.events = [EscapeKey()];
    final result = await run(screen).timeout(overlayTimeout);
    expect(result, isNull);
  });

  test('Ctrl-C cancels (returns null)', () async {
    final screen = fakeScreen();
    canned.events = [ControlKey(ControlCode.ctrlC)];
    final result = await run(screen).timeout(overlayTimeout);
    expect(result, isNull);
  });

  test('no configured providers lists nothing but still cancels cleanly',
      () async {
    final screen = fakeScreen();
    canned.events = [EscapeKey()];
    final result = await run(screen, configured: {}).timeout(overlayTimeout);
    expect(result, isNull);
  });

  test('disabled models are filtered out of the list', () async {
    final screen = fakeScreen();
    // Disabled alpha/a2 and beta/b1 → only alpha/a1 remains.
    canned.events = [
      ControlKey(ControlCode.enter), // select alpha/a1
    ];
    final result = await run(screen, disabled: {'alpha/a2', 'beta/b1'})
        .timeout(overlayTimeout);
    expect(result, 'alpha/a1');
  });

  test('navigate down and up, select the starting model', () async {
    final screen = fakeScreen();
    canned.events = [
      ArrowKey(ArrowDirection.down), // alpha/a1 → alpha/a2
      ArrowKey(ArrowDirection.up), // alpha/a2 → alpha/a1
      ControlKey(ControlCode.enter), // select alpha/a1
    ];
    final result = await run(screen).timeout(overlayTimeout);
    expect(result, 'alpha/a1');
  });

  test('most-recently-used models are surfaced at the top, MRU order',
      () async {
    final screen = fakeScreen();
    // Without MRU the list is [alpha/a1, alpha/a2, beta/b1]. With MRU
    // [beta/b1, alpha/a2] (most recent first), it becomes
    // [beta/b1, alpha/a2, alpha/a1] — so focus 0 selects beta/b1.
    canned.events = [
      ControlKey(ControlCode.enter), // select focus 0 → beta/b1
    ];
    final result = await run(screen, recentlyUsed: ['beta/b1', 'alpha/a2'])
        .timeout(overlayTimeout);
    expect(result, 'beta/b1');
  });

  test('recent refs not in the available set are ignored', () async {
    final screen = fakeScreen();
    // gamma isn't configured, so its refs are dropped; the remaining MRU entry
    // (alpha/a2) still floats to the top.
    canned.events = [
      ControlKey(ControlCode.enter), // focus 0 → alpha/a2
    ];
    final result = await run(screen, recentlyUsed: ['gamma/g1', 'alpha/a2'])
        .timeout(overlayTimeout);
    expect(result, 'alpha/a2');
  });
}
