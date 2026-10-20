import 'package:test/test.dart';
import 'package:tina_token_rate_tui/tina_token_rate_tui.dart';

void main() {
  test('reports 0 with fewer than two samples', () {
    final window = TokenRateWindow();
    final t0 = DateTime.fromMillisecondsSinceEpoch(0);
    expect(window.rate(t0), 0);
    window.sample(t0, 0);
    expect(window.rate(t0), 0);
  });

  test('computes tokens per second across the window', () {
    final window = TokenRateWindow();
    final t0 = DateTime.fromMillisecondsSinceEpoch(0);
    window.sample(t0, 0);
    window.sample(t0.add(Duration(seconds: 2)), 100);
    expect(window.rate(t0.add(Duration(seconds: 2))), closeTo(50, 0.001));
  });

  test('prunes samples that fall outside the window', () {
    final window = TokenRateWindow(window: const Duration(milliseconds: 1000));
    final t0 = DateTime.fromMillisecondsSinceEpoch(0);
    window.sample(t0, 0);
    window.sample(t0.add(Duration(milliseconds: 500)), 25);
    window.sample(t0.add(Duration(milliseconds: 1000)), 50);
    expect(window.rate(t0.add(Duration(milliseconds: 1000))),
        closeTo(50, 0.001));
    expect(window.sampleCount, 3);

    // Advancing time prunes the two oldest samples outside the 1s window.
    window.sample(t0.add(Duration(seconds: 2)), 75);
    expect(window.sampleCount, 2);
    expect(window.rate(t0.add(Duration(seconds: 2))), closeTo(25, 0.001));
  });

  test('coalesces redundant samples within the minimum gap', () {
    final window = TokenRateWindow();
    final t0 = DateTime.fromMillisecondsSinceEpoch(0);
    window.sample(t0, 0);
    window.sample(t0.add(Duration(milliseconds: 100)), 0);
    expect(window.sampleCount, 1);
  });

  test('clear drops all samples', () {
    final window = TokenRateWindow();
    final t0 = DateTime.fromMillisecondsSinceEpoch(0);
    window.sample(t0, 0);
    window.sample(t0.add(Duration(seconds: 1)), 10);
    expect(window.sampleCount, 2);
    window.clear();
    expect(window.sampleCount, 0);
    expect(window.rate(t0), 0);
  });
}
