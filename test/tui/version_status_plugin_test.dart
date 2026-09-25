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
/// a found update paints a persistent alert, and settling up-to-date (or a
/// network miss, which reads the same) clears the line.
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
}
