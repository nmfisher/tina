import 'dart:async';
import 'dart:io';

import 'package:tina_app/tina_app.dart';
import 'package:tina/config.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina_console/testing.dart';
import 'package:tina/tui_coordinator.dart';
import 'package:test/test.dart';

import '../helpers/fake_environment.dart';
import '../helpers/fake_provider.dart';
import '../helpers/fake_stdio.dart';
import '../helpers/fake_terminal_geometry.dart';
import '../helpers/memory_session_store.dart';

/// P1 hook-composition integration test: the REAL init order.
///
/// [TuiCoordinator.create] builds the [SessionController] (whose constructor
/// installs the timer ack hook on `turns.onTurnStarted`) and only afterwards
/// assigns the coordinator's goal-judge hook onto the same field. The bug
/// under test: the goal-judge assignment used to REPLACE the field wholesale,
/// erasing the timer hook — timer fire turns then ran without ever acking and
/// their entries stayed `queued` forever. This test drives the real create()
/// wiring end to end: a real fire on the real service becomes a real turn,
/// the composed hooks both observe it, and the service's window closes.
void main() {
  test(
    'init order: the goal-judge assignment composes with — not replaces — '
    'the timer ack hook (fire → turn → ack → next tick armed)',
    () async {
      final temp = Directory.systemTemp.createTempSync('tina-hook-compose-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final registry = ProviderRegistry(env: const {})
        ..register(
          ProviderDescriptor(
            id: 'test',
            name: 'Test',
            authSources: const [],
            defaultBaseUrl: 'https://example.test',
            builder: (_) => FakeProvider.done(),
          ),
        );
      final config = Config.parse(
        ['--model', 'test/model', '--backend', 'ansi'],
        env: const {},
        registry: registry,
      );
      final app = await buildAppComposition(
        config: config,
        registry: registry,
        provider: FakeProvider.done(),
        store: MemorySessionStore(),
        environment: FakeEnvironment(env: {'HOME': temp.path}),
      );
      // The service's Timer seam, captured from the real create() wiring so
      // the test can tick the REAL armed timers (no sleeps).
      final armed = <_FakeTimer>[];
      final fakeFactory = (Duration duration, void Function() callback) {
        final t = _FakeTimer(duration, callback);
        armed.add(t);
        return t;
      };
      final io = FakeStdio()..hasTerminalValue = false;
      final coordinator = await TuiCoordinator.create(
        app: app,
        io: io,
        terminalGeometry: const FakeTerminalGeometry(columns: 120, lines: 24),
        timerFactoryOverride: (duration, callback) =>
            fakeFactory(duration, callback),
      );
      final controller = coordinator.controller;
      final timers = controller.timers;
      expect(timers, isNotNull, reason: 'the interactive path wires timers');

      // The exact regression: after create() the turn-start seam must know
      // BOTH hooks — the controller's timer hook (chain head) and the
      // coordinator's goal judge (composed onto it).
      final seam = controller.turns.onTurnStarted;
      expect(
        seam,
        isNotNull,
        reason: 'create() must leave a turn-start hook installed',
      );

      // Arm a timer through the REAL service (30s is the floor).
      final outcome = timers!.set(const TimerSpec(
        name: 'hooked',
        interval: Duration(seconds: 30),
        instruction: 'say hooked-check',
      ));
      expect(outcome, isA<TimerSetCreated>());
      expect(armed, hasLength(1), reason: 'the service armed its one-shot');

      // Tick it: the fire becomes a REAL turn on the active conversation.
      armed.single.fire();
      await _pumpUntil(
        () => controller.active.isRunning,
        reason: 'the fire became a live turn',
      );
      expect(
        timers.list().single.state,
        TimerEntryState.running,
        reason: 'the timer hook acked the start — proof it survived the '
            'goal-judge assignment (it used to stay queued forever)',
      );

      // Let the turn finish; the composed judge runs alongside harmlessly
      // (no goals set). The end-ack must close the window and re-arm.
      io.feedBytes('/exit\r\r'.codeUnits);
      await _pumpUntil(
        () => !controller.active.isRunning,
        reason: 'the fire turn ended',
      );
      expect(
        timers.list().single.state,
        TimerEntryState.idle,
        reason: 'the timer hook acked the end (§7.3)',
      );
      expect(timers.list().single.fireCount, 1);
      // The exit path settled nothing (the timer was idle) and the service
      // is disposed by teardown; the entry may remain listed, disarmed.
      await coordinator.run().timeout(const Duration(seconds: 5));
      io.close();
    },
  );
}

Future<void> _pumpUntil(bool Function() test, {String? reason}) async {
  for (var i = 0; i < 200; i++) {
    if (test()) return;
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition not met: ${reason ?? 'pumpUntil'}');
}

/// The service's one-shot Timer seam, same shape as the engine test fake:
/// `fire()` runs the armed tick callback without sleeping.
class _FakeTimer implements Timer {
  _FakeTimer(this.initialDelay, this.callback);

  final Duration initialDelay;
  void Function()? callback;
  bool cancelled = false;

  @override
  int get tick => initialDelay.inMilliseconds;

  @override
  bool get isActive => !cancelled && callback != null;

  @override
  void cancel() {
    cancelled = true;
    callback = null;
  }

  void fire() {
    if (!isActive) throw StateError('timer not active');
    final cb = callback;
    callback = null;
    cb!();
  }
}
