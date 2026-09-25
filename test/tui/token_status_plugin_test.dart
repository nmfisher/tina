import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina/tui/input_status.dart';
import 'package:tina/composition/token_status.dart';
import '../helpers/fake_stdio.dart';

/// End-to-end over the plugin surface: the token-status plugin's three
/// contributions (ledger status source, renderer, priority layout) reach the
/// strip with no host wiring beyond mounting the plugin. The ledger itself
/// comes from the app's own spend-ledger plugin, exactly as in bin/tina.dart's
/// composition, and is looked back up through the scope.
void main() {
  test('the plugin paints live token spend on the strip', () async {
    final runtime = PluginRuntime(
      name: 'token-status-e2e',
      plugins: [
        spendLedgerPlugin(
          RuntimeConfig(maxGlobalTokens: 30000, requestsPerMinute: 0),
        ),
        tokenStatusPlugin(),
      ],
    )..activateSync();
    addTearDown(runtime.dispose);
    final ledger = runtime.scope.lookup(spendLedgerServiceKey) as SpendLedger;

    final io = FakeStdio();
    final screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(100, 24),
      ansi: AnsiCapable.yes,
    );
    final status = InputStatus(
      screen: screen,
      scope: runtime.scope,
      conversationId: () => 'c1',
    )..start();
    addTearDown(status.dispose);

    await Future<void>.delayed(Duration.zero);
    io.written.clear();

    ledger.record(const TokenUsage(inputTokens: 4000, outputTokens: 1000));
    await Future<void>.delayed(Duration.zero);
    // Styled runs interleave SGR resets, so assert per-run fragments.
    expect(io.written.toString(), contains('Σ 5,000'));
    expect(io.written.toString(), contains('/ 30,000 · 17%'));

    io.written.clear();
    ledger.recordEstimated(const TokenUsage(inputTokens: 300, outputTokens: 0));
    await Future<void>.delayed(Duration.zero);
    expect(io.written.toString(), contains('+~300 est'));

    // Mode label and counter share the row: label left, counter right.
    screen.setModeLabel('mode: auto');
    io.written.clear();
    ledger.record(const TokenUsage(inputTokens: 0, outputTokens: 100));
    await Future<void>.delayed(Duration.zero);
    final painted = io.written.toString();
    expect(painted, contains('mode: auto'));
    expect(painted, contains('Σ 5,100'));
    expect(painted, contains('+~300 est'));
    // The share counts measured + estimated (5,400 of 30,000).
    expect(painted, contains('/ 30,000 · 18%'));
  });
}
