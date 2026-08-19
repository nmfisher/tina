import 'package:tina/tui/model_search_overlay.dart';
import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import '../helpers/fake_stdio.dart';
import '../helpers/overlay_fixtures.dart';

/// The searchable, provider-grouped model picker. Drives
/// [runModelSearchOverlay] with canned events; the base list with
/// `alpha` (a1, a2) and `beta` (b1) is:
///
///     Alpha (2)
///       a1
///       a2
///     Beta (1)
///       b1
void main() {
  final canned = CannedEvents();

  setUp(canned.clear);

  (FakeStdio, Screen) rig() {
    final io = FakeStdio()..hasTerminalValue = false;
    final screen =
        Screen(io: io, layout: ScreenLayout.fromSize(80, 24, hasMenuBar: false));
    return (io, screen);
  }

  Future<String?> run(Screen screen,
          {List<String> recent = const [],
          Map<String, String> names = const {}}) =>
      runModelSearchOverlay(
        screen: screen,
        editor: LineEditor(screen: screen),
        modelRefs: const ['alpha/a1', 'alpha/a2', 'beta/b1'],
        providerNames: names,
        recentRefs: recent,
        readEvent: canned.readEvent,
      ).timeout(overlayTimeout);

  test('typing filters to the matching models; enter selects the first',
      () async {
    final (_, screen) = rig();
    canned.events = [
      CharInput('b1'), // matches only beta/b1
      ControlKey(ControlCode.enter),
    ];
    expect(await run(screen), 'beta/b1');
  });

  test('the query matches on the provider name too', () async {
    final (_, screen) = rig();
    canned.events = [
      CharInput('zet'), // provider display name "Zeta"
      ControlKey(ControlCode.enter),
    ];
    expect(await run(screen, names: const {'beta': 'Zeta'}), 'beta/b1');
  });

  test('backspace widens the filter back out', () async {
    final (_, screen) = rig();
    canned.events = [
      CharInput('zz'), // no match
      ControlKey(ControlCode.backspace), // still no match ("z")
      ControlKey(ControlCode.backspace), // empty → all models again
      ControlKey(ControlCode.enter), // focus 0 → alpha/a1
    ];
    expect(await run(screen), 'alpha/a1');
  });

  test('enter with no matches is a no-op, not a cancel', () async {
    final (_, screen) = rig();
    canned.events = [
      CharInput('zz'), // no match
      ControlKey(ControlCode.enter), // ignored — overlay stays up
      ControlKey(ControlCode.backspace),
      ControlKey(ControlCode.backspace),
      ControlKey(ControlCode.enter), // now selects alpha/a1
    ];
    expect(await run(screen), 'alpha/a1');
  });

  test('arrows skip the header rows: down twice reaches the next provider',
      () async {
    final (_, screen) = rig();
    canned.events = [
      ArrowKey(ArrowDirection.down), // a1 → a2
      ArrowKey(ArrowDirection.down), // a2 → b1 (Alpha header skipped)
      ControlKey(ControlCode.enter),
    ];
    expect(await run(screen), 'beta/b1');
  });

  test('recent refs form a Recent group at the top', () async {
    final (io, screen) = rig();
    canned.events = [ControlKey(ControlCode.enter)];
    expect(await run(screen, recent: const ['beta/b1']), 'beta/b1');
    // The rendered frame shows the Recent header and the provider headers.
    final out = io.written.toString();
    expect(out, contains('Recent'));
    expect(out, contains('Alpha'));
    expect(out, contains('Beta'));
  });

  test('the search field and provider headers render', () async {
    final (io, screen) = rig();
    canned.events = [ControlKey(ControlCode.enter)];
    await run(screen);
    final out = io.written.toString();
    expect(out, contains('filter models…'));
    expect(out, contains('Alpha (2)'));
    expect(out, contains('Beta (1)'));
  });

  test('escape cancels', () async {
    final (_, screen) = rig();
    canned.events = [EscapeKey()];
    expect(await run(screen), isNull);
  });
}
