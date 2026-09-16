import 'package:test/test.dart';
import 'package:tina_engine/src/terminal/pty_session.dart';

void main() {
  test('grace longer than three seconds still escalates and awaits survivors',
      () async {
    var now = Duration.zero;
    final kills = <Duration>[];
    final session = PtySession(
      now: () => now,
      delay: (duration) async {
        now += duration;
      },
      signal: (sig) {
        if (sig == 9) {
          kills.add(now);
          return kills.length < 3 ? 1 : 0;
        }
        return 1;
      },
    );
    await session.terminate(grace: const Duration(seconds: 5));
    expect(kills.first, const Duration(seconds: 5));
    expect(kills.length, 3);
    expect(now, const Duration(milliseconds: 5040));
  });

  test('empty session and graceful exit need no force kill', () async {
    final calls = <int>[];
    final session = PtySession(signal: (sig) {
      calls.add(sig);
      return sig == 15 ? 1 : 0;
    });
    await session.terminate(grace: const Duration(seconds: 2));
    expect(calls, [15, 0]);
  });

  test('enumeration failures are errors, not successful empty sessions',
      () async {
    final session =
        PtySession(signal: (_) => throw StateError('no process table'));
    await expectLater(
        session.terminate(grace: Duration.zero), throwsStateError);
  });

  test('unkillable processes hit an explicit bounded cleanup failure',
      () async {
    var now = Duration.zero;
    final session = PtySession(
        signal: (_) => 1,
        now: () => now,
        delay: (duration) async {
          now += duration;
        });
    await expectLater(
        session.terminate(grace: Duration.zero), throwsStateError);
    expect(now, const Duration(seconds: 1));
  });
}
