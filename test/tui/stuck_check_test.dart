import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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

  group('stall heal', () {
    late _HealBackend backend;
    late FakeStdio healIo;
    late Screen healScreen;
    late LineEditor healEditor;

    setUp(() {
      backend = _HealBackend();
      healIo = FakeStdio();
      healScreen = Screen.withBackend(
        backend: backend,
        io: healIo,
        layout: ScreenLayout.fromSize(80, 24),
        ansi: AnsiCapable.yes,
      );
      healEditor = LineEditor(screen: healScreen, escapeTimeout: Duration.zero);
    });

    tearDown(() => healEditor.close(reportLatency: false));

    StuckCheck healCheck({bool heal = true}) {
      final c = StuckCheck(
        screen: healScreen,
        editor: healEditor,
        heal: heal,
        stallAfter: const Duration(seconds: 30),
        busyStallAfter: const Duration(seconds: 60),
        clock: () => now,
      );
      c.start();
      c.stop();
      return c;
    }

    /// The freeze shape: a key reaches the editor and no frame reaches the
    /// terminal. The monitor bracket keeps the input stream subscribed.
    Future<void> keyWithNothingDrawn() async {
      healEditor.beginCancelMonitor(() {});
      healEditor.endCancelMonitor();
      healIo.feedBytes(utf8.encode('x'));
      await _settle();
      expect(healEditor.keyCount, 1);
    }

    test('the first reported stall forces one full repaint', () async {
      final c = healCheck();
      await keyWithNothingDrawn();
      now = now.add(const Duration(seconds: 31));
      c.checkNow();

      final warnings = messages('keys are arriving but nothing has been drawn');
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('forcing a full repaint'));
      expect(backend.refreshes, 1,
          reason: 'the heal re-emits the retained frame in full');

      // Still stuck: the same episode is neither re-healed nor re-reported.
      now = now.add(const Duration(seconds: 10));
      c.checkNow();
      expect(backend.refreshes, 1);
      expect(messages('keys are arriving but nothing has been drawn'),
          hasLength(1));

      // A real presentation after the heal closes the episode as usual.
      backend.presented++;
      c.checkNow();
      expect(messages('the screen is drawing again'), hasLength(1));
      expect(backend.refreshes, 1, reason: 'recovery is not a second heal');
    });

    test('heal: false reports the stall without touching the backend',
        () async {
      final c = healCheck(heal: false);
      await keyWithNothingDrawn();
      now = now.add(const Duration(seconds: 31));
      c.checkNow();

      final warnings = messages('keys are arriving but nothing has been drawn');
      expect(warnings, hasLength(1));
      expect(backend.refreshes, 0,
          reason: 'detection-only checks must leave the backend alone');
      // ...and the line must not claim otherwise. The log is the *only* product
      // in this mode, so a "forcing a full repaint" clause would be a false
      // report about the one thing a reader can check.
      expect(warnings.single, isNot(contains('forcing a full repaint')),
          reason: 'a log-only check must not advertise a heal it will not run');
    });
  });
}

/// A backend that reports frame diagnostics and counts full refreshes, so the
/// stuck check's heal can be observed without a terminal. [presented] is
/// scripted by the test; [refresh] is recorded but deliberately does NOT bump
/// it — that is the retention desync the heal exists to patch (the backend
/// believes it has nothing to re-emit).
class _HealBackend implements TerminalBackend, BackendDiagnostics {
  int presented = 0;
  int refreshes = 0;

  @override
  int get presentedFrames => presented;

  @override
  int get openFrames => 0;

  @override
  bool get flushPending => false;

  @override
  bool get gridDirty => false;

  @override
  void refresh() => refreshes++;

  @override
  void moveCursor(int row, int col) {}

  @override
  void beginFrame() {}

  @override
  void endFrame() {}

  @override
  void parkCursor(int row, int col) {}

  @override
  void eraseCells(int row, int col, int n) {}

  @override
  void writeText(String text) {}

  @override
  void saveCursor() {}

  @override
  void restoreCursor() {}

  @override
  void flush() {}

  @override
  void enterAltScreen() {}

  @override
  void leaveAltScreen() {}

  @override
  void enableBracketedPaste() {}

  @override
  void disableBracketedPaste() {}

  @override
  bool get supportsColor => true;

  @override
  String colorize(String code, String text) => '\x1b[${code}m$text\x1b[0m';

  @override
  Stream<List<int>> get stdin => const Stream.empty();

  @override
  int get terminalColumns => 80;

  @override
  void renderImageAbsolute({
    required int row,
    required int col,
    required Uint32List rgba,
    required int width,
    required int height,
    required int maxCols,
    BackendSurface? targetSurface,
  }) {}

  @override
  BackendSurface createSurface(Rect bounds) =>
      throw UnimplementedError('not used in this test');

  @override
  bool get coalescesPaints => false;
}
