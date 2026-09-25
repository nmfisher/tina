import 'package:test/test.dart';

import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/backend/ansi_backend.dart';

import 'stdio_fake.dart';
import 'package:dart_notcurses/dart_notcurses.dart' as nc;
import 'package:tina_console/src/backend/notcurses_backend.dart';
import 'notcurses_backend_platform_test.dart' show RecordingPlatform;
import 'virtual_terminal.dart';

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
  group('backend surface bounds', () {
    for (final native in [false, true]) {
      group(
          native
              ? 'NotcursesBackendSurface bounds'
              : 'AnsiBackendSurface bounds', () {
        late BackendSurface surface;
        late FakeStdio io;
        late _Plane plane;
        late RecordingPlatform platform;
        const bounds = Rect(row: 2, col: 3, width: 6, height: 2);
        setUp(() {
          io = FakeStdio();
          plane = _Plane();
          platform = RecordingPlatform();
          surface = native
              ? NotcursesBackendSurface(plane, platform, bounds)
              : AnsiBackendSurface(
                  AnsiBackend(io: io, ansi: AnsiCapable.yes), bounds);
        });

        test('invalid origins and nonpositive budgets do no backend work', () {
          for (final (row, col, width) in [
            (0, 0, -1),
            (0, 0, 0),
            (0, 6, 5),
            (0, 8, 5),
            (0, -1, 5),
            (-1, 0, 5),
            (2, 0, 5),
          ]) {
            surface.putAt(
                relRow: row,
                relCol: col,
                text: 'bad',
                maxCols: width,
                clearCells: 0,
                moveCursor: false);
            surface.eraseAt(
                relRow: row, relCol: col, n: width, moveCursor: false);
          }
          expect(plane.calls, isEmpty);
          expect(plane.writes, isEmpty);
          expect(platform.calls, isEmpty);
          expect(io.written.toString(), isEmpty);
        });

        test('oversized writes and erases stop at the surface edge', () {
          surface.putAt(
              relRow: 0,
              relCol: 4,
              text: 'abcdef',
              maxCols: 100,
              clearCells: 100,
              moveCursor: false);
          surface.eraseAt(relRow: 1, relCol: 5, n: 100, moveCursor: false);
          if (native) {
            expect(plane.writes, contains((row: 0, col: 4, text: 'ab')));
            expect(plane.writes.last, (row: 1, col: 5, text: ' '));
            expect(
                plane.writes.every(
                    (write) => write.col + write.text.length <= bounds.width),
                isTrue);
          } else {
            final vt = VirtualTerminal(width: 30, height: 10);
            // Sentinels outside the surface must survive both operations.
            vt.feed('\x1b[3;10H|\x1b[4;9Hx|');
            vt.feed(io.written.toString());
            expect(vt.rowText(2).substring(7, 9), 'ab');
            expect(vt.rowText(2).substring(9).trim(), '|');
            expect(vt.rowText(3).substring(8, 10), ' |');
          }
        });
      });
    }
  });
}

class _Plane implements nc.Plane {
  final calls = <String>[];
  final writes = <({int row, int col, String text})>[];
  @override
  void setFgDefault() => calls.add('fgDefault');
  @override
  void setBgDefault() => calls.add('bgDefault');
  @override
  void setStyles(int styles) => calls.add('styles');
  @override
  int putStrYX(int row, int col, String text) {
    writes.add((row: row, col: col, text: text));
    return text.length;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
