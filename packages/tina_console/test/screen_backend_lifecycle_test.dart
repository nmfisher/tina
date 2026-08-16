import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tina_console/tina_console.dart';
import 'stdio_fake.dart';

/// Records every call to its [TerminalBackend] surface, in order. Used to
/// pin down the exact sequence [Screen] issues during its lifecycle — so we
/// can spot ordering hazards (like `flush()` after `leaveAltScreen()`,
/// which translates to `nc.render()` after `nc.stop()` on the real notcurses
/// backend).
class RecordingBackend implements TerminalBackend {

  // No retained damage model in this fake; refresh is a no-op.
  @override
  void refresh() {}
  final List<String> calls = [];
  int _frameDepth = 0;
  bool _flushPending = false;

  @override
  void beginFrame() => _frameDepth++;

  @override
  void endFrame() {
    if (_frameDepth == 0) return;
    _frameDepth--;
    if (_frameDepth == 0 && _flushPending) {
      _flushPending = false;
      calls.add('flush');
    }
  }

  @override
  void parkCursor(int row, int col) => calls.add('park($row,$col)');

  @override
  void moveCursor(int row, int col) => calls.add('move($row,$col)');

  @override
  void eraseCells(int row, int col, int n) => calls.add('erase($row,$col,$n)');

  @override
  void writeText(String text) => calls.add('write(${text.length})');

  @override
  void saveCursor() => calls.add('save');

  @override
  void restoreCursor() => calls.add('restore');

  @override
  void flush() {
    if (_frameDepth > 0) {
      _flushPending = true;
      return;
    }
    calls.add('flush');
  }

  @override
  void enterAltScreen() => calls.add('enter');

  @override
  void leaveAltScreen() => calls.add('leave');

  @override
  void enableBracketedPaste() => calls.add('enablePaste');

  @override
  void disableBracketedPaste() => calls.add('disablePaste');

  @override
  bool get supportsColor => true;

  // Synchronous-style recording backend: no coalesced chat scheduling.
  @override
  bool get coalescesPaints => false;

  @override
  String colorize(String code, String text) => '\x1b[${code}m$text\x1b[0m';

  @override
  Stream<List<int>> get stdin => const Stream.empty();

  @override
  int get terminalColumns => 80;

  @override
  BackendSurface createSurface(Rect bounds) {
    // Unused by the lifecycle tests; present to satisfy the interface.
    throw UnimplementedError('RecordingBackend.createSurface is unused');
  }

  @override
  void renderImageAbsolute({
    required int row,
    required int col,
    required Uint32List rgba,
    required int width,
    required int height,
    required int maxCols,
    BackendSurface? targetSurface,
  }) =>
      calls.add('image($row,$col,${width}x$height)');
}

void main() {
  group('Screen lifecycle via TerminalBackend', () {
    late FakeStdio io;
    late RecordingBackend backend;
    late Screen screen;

    setUp(() {
      // 120-col layout puts ScreenLayout in split mode so redrawFrame is
      // active and we can observe Screen issuing actual paint operations.
      io = FakeStdio()..columns = 120;
      backend = RecordingBackend();
      screen = Screen.withBackend(
        backend: backend,
        io: io,
        layout: ScreenLayout.fromSize(120, 30),
      );
    });

    test('enterAltScreen emits enter, then enableBracketedPaste, then flush',
        () {
      screen.enterAltScreen();
      expect(backend.calls.first, 'enter');
      final enterIdx = backend.calls.indexOf('enter');
      final pasteIdx = backend.calls.indexOf('enablePaste');
      final flushIdx = backend.calls.indexOf('flush');
      expect(pasteIdx, greaterThan(enterIdx),
          reason: 'bracketed paste is enabled after entering the alt screen');
      expect(flushIdx, greaterThan(pasteIdx),
          reason: 'flush comes after the paste escape is queued');
    });

    test('leaveAltScreen disables paste before leave, then flushes', () {
      // This documents the ordering that breaks the notcurses backend if
      // its flush isn't post-stop-safe. Screen calls disableBracketedPaste,
      // leaveAltScreen, then flush. NotcursesBackend handles this by setting
      // a _stopped flag on leave so the following flush becomes a no-op.
      screen.enterAltScreen();
      backend.calls.clear();
      screen.leaveAltScreen();
      final disableIdx = backend.calls.indexOf('disablePaste');
      final leaveIdx = backend.calls.indexOf('leave');
      final flushIdx = backend.calls.indexOf('flush');
      expect(disableIdx, greaterThanOrEqualTo(0));
      expect(leaveIdx, greaterThan(disableIdx),
          reason: 'leaveAltScreen runs after bracketed paste is disabled');
      expect(flushIdx, greaterThan(leaveIdx),
          reason: 'Screen.leaveAltScreen() emits leave + flush in order; '
              'the backend must tolerate a flush after leave.');
    });

    test('enterAltScreen is idempotent', () {
      screen.enterAltScreen();
      final firstCalls = List.of(backend.calls);
      screen.enterAltScreen();
      expect(backend.calls, equals(firstCalls),
          reason: 'second enterAltScreen should be a no-op');
    });

    test('leaveAltScreen without enter is a no-op', () {
      screen.leaveAltScreen();
      expect(backend.calls, isEmpty);
    });

    test('writes are clipped to layout bounds then dispatched to backend', () {
      screen.enterAltScreen();
      backend.calls.clear();

      screen.chat.write('hello\n');

      // We expect at minimum a positioning + write + flush.
      expect(backend.calls.any((c) => c.startsWith('move')), isTrue);
      expect(backend.calls.any((c) => c.startsWith('write')), isTrue);
      expect(backend.calls.last, 'flush');
    });

    test('colorize delegates to backend', () {
      expect(screen.colorize('31', 'hi'), '\x1b[31mhi\x1b[0m');
    });
  });
}
