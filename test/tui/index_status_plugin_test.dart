import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina/tui/input_status.dart';
import 'package:tina/composition/index_status.dart';
import '../helpers/fake_stdio.dart';

/// End-to-end over the plugin surface: the index-status plugin's source and
/// renderer reach the strip with no host wiring beyond mounting the plugins —
/// the progress service from [indexProgressPlugin], exactly as bin/tina.dart's
/// composition does. While no run is active the strip shows nothing; begin,
/// progress updates and end repaint it live, and cancellation/teardown clears
/// the line.
void main() {
  test('the plugin paints live indexing progress on the strip', () async {
    final runtime = PluginRuntime(
      name: 'index-status-e2e',
      plugins: [indexProgressPlugin(), indexStatusPlugin()],
    )..activateSync();
    addTearDown(runtime.dispose);
    final status =
        runtime.scope.lookup(indexProgressServiceKey) as IndexProgressStatus;

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
    expect(io.written.toString(), isNot(contains('indexing')));

    status.begin();
    await Future<void>.delayed(Duration.zero);
    // Announced but nothing settled yet: spinner without a confusing 0/0.
    expect(io.written.toString(), contains('indexing'));
    expect(io.written.toString(), isNot(contains('/0')));
    expect(io.written.toString(), isNot(contains('0/0')));

    io.written.clear();
    status.progress(3, 18);
    await Future<void>.delayed(Duration.zero);
    final painted = io.written.toString();
    expect(painted, contains('indexing'));
    expect(painted, contains('3/18'));

    io.written.clear();
    status.end();
    await Future<void>.delayed(Duration.zero);
    expect(
      io.written.toString(),
      isNot(contains('indexing')),
      reason: 'the line leaves the strip once the run ends',
    );
  });
}
