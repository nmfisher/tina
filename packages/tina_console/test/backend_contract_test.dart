import 'package:test/test.dart';

import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/backend/ansi_backend.dart';

import 'stdio_fake.dart';

void main() {
  group('Backend contract (AnsiBackend)', () {
    late FakeStdio io;
    late AnsiBackend backend;

    setUp(() {
      io = FakeStdio()..columns = 100;
      backend = AnsiBackend(io: io, ansi: AnsiCapable.yes);
    });

    test('moveCursor emits correct positioning sequence', () {
      backend.moveCursor(2, 5);
      backend.flush();
      expect(io.written.toString(), contains('\x1b[3;6H'));
    });

    test('eraseCells emits move + erase sequence', () {
      backend.eraseCells(0, 0, 10);
      backend.flush();
      final out = io.written.toString();
      expect(out, contains('\x1b[1;1H'));
      expect(out, contains('\x1b[10X'));
    });

    test('writeText emits raw text', () {
      backend.writeText('hello');
      backend.flush();
      expect(io.written.toString(), 'hello');
    });

    test('saveCursor and restoreCursor emit escape sequences', () {
      backend.saveCursor();
      backend.writeText('test');
      backend.restoreCursor();
      backend.flush();
      final out = io.written.toString();
      expect(out, contains('\x1b7'));
      expect(out, contains('test'));
      expect(out, contains('\x1b8'));
    });

    test('enterAltScreen emits escape', () {
      backend.enterAltScreen();
      backend.flush();
      expect(io.written.toString(), '\x1b[?1049h');
    });

    test('leaveAltScreen emits escape', () {
      backend.leaveAltScreen();
      backend.flush();
      expect(io.written.toString(), '\x1b[?1049l');
    });

    test('enableBracketedPaste emits DECSET 2004', () {
      backend.enableBracketedPaste();
      backend.flush();
      expect(io.written.toString(), '\x1b[?2004h');
    });

    test('disableBracketedPaste emits DECRST 2004', () {
      backend.enableBracketedPaste();
      backend.disableBracketedPaste();
      backend.flush();
      expect(io.written.toString(), '\x1b[?2004h\x1b[?2004l');
    });

    test('enableBracketedPaste is idempotent', () {
      backend.enableBracketedPaste();
      backend.enableBracketedPaste();
      backend.flush();
      expect(io.written.toString(), '\x1b[?2004h',
          reason: 'second enable is a no-op');
    });

    test('disableBracketedPaste without enable is a no-op', () {
      backend.disableBracketedPaste();
      backend.flush();
      expect(io.written.toString(), isEmpty);
    });

    test('colorize wraps text when color is enabled', () {
      final result = backend.colorize('31', 'red text');
      expect(result, '\x1b[31mred text\x1b[0m');
    });

    test('colorize passes through when color is disabled', () {
      final noColor = AnsiBackend(io: io, ansi: AnsiCapable.no);
      final result = noColor.colorize('31', 'plain text');
      expect(result, 'plain text');
    });

    test('flush writes buffer to Stdio', () {
      backend.writeText('abc');
      // Not flushed yet.
      expect(io.written.toString(), isEmpty);
      backend.flush();
      expect(io.written.toString(), 'abc');
    });

    test('multiple operations batch until flush', () {
      backend.moveCursor(0, 0);
      backend.writeText('hello');
      backend.moveCursor(1, 0);
      backend.writeText('world');
      backend.flush();
      final out = io.written.toString();
      expect(out, contains('hello'));
      expect(out, contains('world'));
      // Two cursor moves — two CSI sequences.
      expect(out, contains('\x1b[1;1H'));
      expect(out, contains('\x1b[2;1H'));
    });

    test('supportsColor reflects AnsiCapable', () {
      expect(backend.supportsColor, isTrue);
      final noColor = AnsiBackend(io: io, ansi: AnsiCapable.no);
      expect(noColor.supportsColor, isFalse);
    });

    test('terminalColumns delegates to Stdio', () {
      expect(backend.terminalColumns, 100);
    });
  });

  group('Backend contract (via Screen)', () {
    test('Screen with AnsiBackend renders a frame correctly', () {
      final io = FakeStdio()..columns = 100;
      final layout = ScreenLayout.fromSize(100, 30, hasMenuBar: false);
      final screen = Screen(io: io, layout: layout);

      screen.enterAltScreen();
      final out = io.written.toString();

      // Alt screen escape should be present.
      expect(out, contains('\x1b[?1049h'));
      // Frame borders should be present — two boxes (chat + info) each
      // contribute their own corner set.
      expect(out, contains('┌'));
      expect(out, contains('┐'));
      expect(out, contains('└'));
      expect(out, contains('┘'));
      // No ┬/┴/┼ dividers — the new layout is two independent boxes.
      expect(out, isNot(contains('┬')));
      expect(out, isNot(contains('┴')));
    });

    test('Screen.putAtAbsolute clips and positions via backend', () {
      final io = FakeStdio()..columns = 100;
      final layout = ScreenLayout.fromSize(100, 30, hasMenuBar: false);
      final screen = Screen(io: io, layout: layout);

      screen.enterAltScreen();
      io.written.clear();

      screen.chat.write('hello');

      // The output should contain cursor positioning and the text.
      final out = io.written.toString();
      expect(out, contains('hello'));
      expect(out, contains('\x1b[')); // Some cursor positioning.
    });

    test('Screen.eraseAtAbsolute clears cells via backend', () {
      final io = FakeStdio()..columns = 100;
      final layout = ScreenLayout.fromSize(100, 30, hasMenuBar: false);
      final screen = Screen(io: io, layout: layout);

      screen.enterAltScreen();
      io.written.clear();

      screen.chat.write('test text');
      io.written.clear();

      screen.eraseChatArea();

      // The output should contain erase sequences and border repairs.
      final out = io.written.toString();
      expect(out, contains('\x1b[')); // Cursor positioning + erase.
    });
  });
}
