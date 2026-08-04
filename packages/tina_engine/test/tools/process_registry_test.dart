import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  // The registry is a process-global singleton, so each test uses distinct
  // sentinel pids and cleans up after itself to avoid cross-test leakage.

  test('track/untrack/isTracking round-trip', () {
    final reg = ChildProcessRegistry.instance;
    reg.untrack(700001); // start clean
    reg.track(700001);
    expect(reg.isTracking(700001), isTrue);
    reg.untrack(700001);
    expect(reg.isTracking(700001), isFalse);
  });

  test('track ignores non-positive pids', () {
    final reg = ChildProcessRegistry.instance;
    reg.track(0);
    reg.track(-5);
    expect(reg.isTracking(0), isFalse);
    expect(reg.isTracking(-5), isFalse);
  });

  test('reapAll clears the registry', () async {
    final reg = ChildProcessRegistry.instance;
    // Very-high pids are almost certainly not real processes; killProcessTree
    // swallows the resulting errors. reapAll must still clear the set.
    reg.track(800001);
    reg.track(800002);
    await reg.reapAll(grace: Duration.zero);
    expect(reg.isTracking(800001), isFalse);
    expect(reg.isTracking(800002), isFalse);
  });
}
