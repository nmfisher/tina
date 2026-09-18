import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:tina/tui/stuck_check.dart';
import 'package:tina_console/tina_console.dart';

import '../helpers/fake_stdio.dart';

// The stuck check is what makes a freeze visible without the user doing
// anything: a frozen screen cannot be typed into, so the check has to notice by
// itself. These tests step its clock instead of sleeping.

/// The `agent_busy` flag normally comes from the app wiring; tests set it
/// directly.
void _setAgentBusy(LineEditor editor, bool busy) {
  editor.describeState = () => {'agent_busy': busy};
}

Future<void> _settle() async {
  await Future<void>.microtask(() {});
  await Future<void>.microtask(() {});
  await Future<void>.delayed(Duration.zero);
}

void main() {
  late FakeStdio io;
  late Screen screen;
  late LineEditor editor;
  late DateTime now;
  late List<LogRecord> records;
  late StreamSubscription<LogRecord> sub;

  setUp(() {
    io = FakeStdio();
    screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(80, 24),
      ansi: AnsiCapable.yes,
    );
    editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
    now = DateTime(2026, 9, 18, 12);
    records = [];
    sub = Logger.root.onRecord.listen(records.add);
    Logger.root.level = Level.ALL;
  });

  tearDown(() async {
    await sub.cancel();
    Logger.root.level = Level.INFO;
    editor.close(reportLatency: false);
  });

  StuckCheck check({Duration stall = const Duration(seconds: 30)}) {
    final c = StuckCheck(
      screen: screen,
      editor: editor,
      stallAfter: stall,
      busyStallAfter: stall * 2,
      clock: () => now,
    );
    // Establish the baseline without leaving a real timer behind.
    c.start();
    c.stop();
    return c;
  }

  List<String> messages(String needle) => records
      .map((r) => r.message)
      .where((m) => m.contains(needle))
      .toList();

  test('an idle screen is never reported', () {
    final c = check();
    now = now.add(const Duration(minutes: 10));
    c.checkNow();
    expect(messages('nothing has been drawn'), isEmpty,
        reason: 'a chat prompt waiting for input draws nothing and is healthy');
  });

  test('a drawing screen is never reported', () {
    final c = check();
    for (var i = 0; i < 5; i++) {
      now = now.add(const Duration(seconds: 20));
      screen.putAtAbsolute(
        row: 0,
        col: 0,
        text: 'x',
        maxCols: 1,
        moveCursor: false,
      );
      c.checkNow();
    }
    expect(messages('nothing has been drawn'), isEmpty);
  });

  test('keys arriving with nothing drawn is reported once, then recovery',
      () async {
    final c = check();

    // The freeze signature: a key reaches the editor while nothing owns the
    // keyboard, so it is dropped and nothing is redrawn.
    editor.beginCancelMonitor(() {});
    editor.endCancelMonitor();
    io.feedBytes(utf8.encode('x'));
    await _settle();
    expect(editor.keyCount, 1);

    now = now.add(const Duration(seconds: 31));
    c.checkNow();

    final warnings = messages('keys are arriving but nothing has been drawn');
    expect(warnings, hasLength(1));
    expect(warnings.single, contains('31s'));
    expect(warnings.single, contains('chat_prompt_open=false'));

    // Still stuck: no second warning for the same episode.
    now = now.add(const Duration(seconds: 10));
    c.checkNow();
    expect(messages('keys are arriving but nothing has been drawn'),
        hasLength(1));

    // Drawing resumes: the episode is closed off in the log.
    screen.putAtAbsolute(
      row: 0,
      col: 0,
      text: 'back',
      maxCols: 4,
      moveCursor: false,
    );
    c.checkNow();
    expect(messages('the screen is drawing again'), hasLength(1));
  });

  test('a key typed before the stall window is not forgotten', () async {
    final c = check();

    editor.beginCancelMonitor(() {});
    editor.endCancelMonitor();
    io.feedBytes(utf8.encode('x'));
    await _settle();

    // A look while the stall is still short: nothing to report yet, but the
    // key must be remembered.
    now = now.add(const Duration(seconds: 10));
    c.checkNow();
    expect(messages('keys are arriving but nothing has been drawn'), isEmpty);

    // The user stopped typing; the stall is now long enough. Still reported.
    now = now.add(const Duration(seconds: 25));
    c.checkNow();
    expect(messages('keys are arriving but nothing has been drawn'),
        hasLength(1));
  });

  test('an agent that says it is busy with nothing drawn is reported', () {
    final c = check();
    _setAgentBusy(editor, true);

    now = now.add(const Duration(seconds: 61));
    c.checkNow();

    final warnings = messages('the agent says it is busy');
    expect(warnings, hasLength(1));
    expect(warnings.single, contains('agent_busy=true'));
  });

  test('a long think below the busy threshold is not reported', () {
    final c = check();
    _setAgentBusy(editor, true);

    now = now.add(const Duration(seconds: 45));
    c.checkNow();

    expect(messages('the agent says it is busy'), isEmpty);
  });
}
