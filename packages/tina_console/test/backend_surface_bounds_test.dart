import 'package:dart_notcurses/dart_notcurses.dart' as nc;
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/backend/ansi_backend.dart';
import 'package:tina_console/src/backend/notcurses_backend.dart';

import 'notcurses_backend_platform_test.dart' show RecordingPlatform;
import 'stdio_fake.dart';
import 'virtual_terminal.dart';

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

void main() {
  for (final native in [false, true]) {
    group(
        native ? 'NotcursesBackendSurface bounds' : 'AnsiBackendSurface bounds',
        () {
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
}
