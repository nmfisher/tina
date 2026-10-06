import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/backend/ansi_backend.dart';
import 'package:tina_console/src/backend/notcurses_backend.dart';

import 'notcurses_backend_platform_test.dart' show RecordingPlatform;
import 'stdio_fake.dart';

void main() {
  test('ANSI attention flushes BEL without changing cells or cursor', () {
    final io = FakeStdio();
    addTearDown(() {
      io.close();
    });
    final backend = AnsiBackend(io: io, ansi: AnsiCapable.yes);
    backend.moveCursor(2, 3);
    backend.flush();
    io.written.clear();
    backend.requestAttention();
    expect(io.written.toString(), '\x07');
    expect(backend.gridDirty, false);
    io.written.clear();
    backend.moveCursor(2, 3);
    backend.flush();
    expect(io.written.toString(), isEmpty,
        reason: 'attention must preserve the cached cursor position');
    backend.beginFrame();
    backend.requestAttention();
    expect(io.written.toString(), isEmpty);
    backend.endFrame();
    expect(io.written.toString(), '\x07');
  });

  test('notcurses sends BEL to the tty without drawing or rendering', () {
    final platform = RecordingPlatform();
    final io = FakeStdio();
    addTearDown(() {
      io.close();
    });
    final backend = NotcursesBackend.forTesting(io: io, platform: platform);
    backend.enterAltScreen();
    platform.calls.clear();
    platform.rawTtyWrites.clear();
    backend.requestAttention();
    expect(platform.rawTtyWrites, ['\x07']);
    expect(platform.calls, hasLength(1));
    expect(backend.gridDirty, false);
    backend.leaveAltScreen();
    platform.calls.clear();
    platform.rawTtyWrites.clear();
    backend.requestAttention();
    expect(platform.calls, isEmpty);
    expect(platform.rawTtyWrites, isEmpty);
  });

  test('screen attention is limited to its active alternate screen', () {
    final io = FakeStdio();
    addTearDown(() {
      io.close();
    });
    final screen =
        Screen(io: io, layout: ScreenLayout.fromSize(80, 24, split: false));
    addTearDown(screen.dispose);
    screen.requestAttention();
    expect(io.written.toString(), isEmpty);
    screen.enterAltScreen();
    io.written.clear();
    screen.requestAttention();
    expect(io.written.toString(), '\x07');
    screen.leaveAltScreen();
    io.written.clear();
    screen.requestAttention();
    expect(io.written.toString(), isEmpty);
    final plain = Screen.passthrough(io);
    addTearDown(plain.dispose);
    plain.enterAltScreen();
    plain.requestAttention();
    expect(io.written.toString(), isEmpty);
  });
}
