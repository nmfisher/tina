import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina/tui/input_status.dart';
import 'package:tina/composition/version_status.dart';
import '../helpers/fake_stdio.dart';

/// End-to-end over the plugin surface: the version-status plugin's source and
/// renderer reach the strip with no host wiring beyond mounting the plugins —
/// the check state from [versionStatusPlugin], exactly as bin/tina.dart's
/// composition does. Idle shows nothing; the running check paints a spinner,
/// a found update paints a persistent alert, settling up-to-date clears the
/// line, and a miss paints a dim failure line that a later finding replaces.
void main() {
  test('the plugin paints the release check and update alert on the strip', () async {
    final runtime = PluginRuntime(
      name: 'version-status-e2e',
      plugins: [versionStatusPlugin(), versionStatusUiPlugin()],
    )..activateSync();
    addTearDown(runtime.dispose);
    final status =
        runtime.scope.lookup(versionStatusServiceKey) as VersionStatus;

    final io = FakeStdio();
    final screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(100, 24),
      ansi: AnsiCapable.yes,
    );
    final strip = InputStatus(
      screen: screen,
      scope: runtime.scope,
      conversationId: () => 'c1',
    )..start();
    addTearDown(strip.dispose);

    await Future<void>.delayed(Duration.zero);
    expect(io.written.toString(), isNot(contains('update check')));

    status.beginCheck();
    await Future<void>.delayed(Duration.zero);
    expect(io.written.toString(), contains('update check'));

    io.written.clear();
    status.updateAvailable('v0.9.0');
    await Future<void>.delayed(Duration.zero);
    final painted = io.written.toString();
    expect(painted, contains('v0.9.0'));
    expect(painted, contains('/update'));
    // The alert persists: a settling tick must not drop it.
    expect(status.read('c1'), isNotNull);

    io.written.clear();
    status.upToDate();
    await Future<void>.delayed(Duration.zero);
    expect(
      io.written.toString(),
      isNot(contains('/update')),
      reason: 'the line leaves the strip once the check settles idle',
    );
    expect(status.read('c1'), isNull);
  });

  test('a missed check paints a dim failure line, not silence', () async {
    final runtime = PluginRuntime(
      name: 'version-status-miss-e2e',
      plugins: [versionStatusPlugin(), versionStatusUiPlugin()],
    )..activateSync();
    addTearDown(runtime.dispose);
    final status =
        runtime.scope.lookup(versionStatusServiceKey) as VersionStatus;

    final io = FakeStdio();
    final screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(100, 24),
      ansi: AnsiCapable.yes,
    );
    final strip = InputStatus(
      screen: screen,
      scope: runtime.scope,
      conversationId: () => 'c1',
    )..start();
    addTearDown(strip.dispose);

    status.missed('HTTP 403 (likely rate-limited)');
    await Future<void>.delayed(Duration.zero);
    final painted = io.written.toString();
    expect(painted, contains('update check failed'));
    expect(painted, contains('HTTP 403 (likely rate-limited)'));
    // A miss is dim, not alarm-colored: it must not borrow the alert's
    // yellow or its `/update` cue.
    expect(painted, isNot(contains('/update')));

    // A later finding replaces the miss — the alert must be able to surface
    // after a failed first attempt (e.g. `/update` succeeding).
    io.written.clear();
    status.updateAvailable('v0.9.0');
    await Future<void>.delayed(Duration.zero);
    final after = io.written.toString();
    expect(after, contains('v0.9.0'));
    expect(after, contains('/update'));
    expect(after, isNot(contains('update check failed')));
  });

  test('a deferred check paints a quiet retry line, not an alarm', () async {
    final runtime = PluginRuntime(
      name: 'version-status-deferred-e2e',
      plugins: [versionStatusPlugin(), versionStatusUiPlugin()],
    )..activateSync();
    addTearDown(runtime.dispose);
    final status =
        runtime.scope.lookup(versionStatusServiceKey) as VersionStatus;

    final io = FakeStdio();
    final screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(100, 24),
      ansi: AnsiCapable.yes,
    );
    final strip = InputStatus(
      screen: screen,
      scope: runtime.scope,
      conversationId: () => 'c1',
    )..start();
    addTearDown(strip.dispose);

    status.deferred(DateTime.now().add(const Duration(minutes: 42)),
        release: 'v0.8.32');
    await Future<void>.delayed(Duration.zero);
    final painted = io.written.toString();
    expect(painted, contains('update check deferred'));
    expect(painted, contains('retry '));
    expect(painted, contains('last known v0.8.32'));
    // Quiet state: no alert cue, no failure wording.
    expect(painted, isNot(contains('/update')));
    expect(painted, isNot(contains('failed')));

    // A later finding still replaces it.
    io.written.clear();
    status.updateAvailable('v0.9.0');
    await Future<void>.delayed(Duration.zero);
    expect(io.written.toString(), contains('/update'));
  });
}
