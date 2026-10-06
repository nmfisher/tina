import 'package:test/test.dart';

import 'package:dart_notcurses/dart_notcurses.dart' as nc;
import 'package:tina_console/src/backend/backend_surface.dart';
import 'package:tina_console/src/backend/input_backend.dart';
import 'package:tina_console/src/backend/notcurses_backend.dart';
import 'package:tina_console/src/rect.dart';
import 'package:tina_console/src/screen.dart';
import 'package:tina_console/src/screen_layout.dart';

import 'stdio_fake.dart';

/// Regression coverage for tin-4k8w (chat-region corruption on mid-stream
/// resize): the terminal (tmux foremost) scrolls the alternate screen when a
/// pane shrinks, so the terminal's grid no longer matches the backend's
/// retained frame and damage-only repaints leave the dropped rows stale
/// forever. The fix is a full re-emission ([Screen.refresh] →
/// [NotcursesBackend.refresh] → notcurses_refresh) at the end of every
/// resize; these tests pin the forwarding chain and the post-refresh cursor
/// re-park. Same-size SIGWINCH repaints also recover external terminal writes.
void main() {
  test('Screen.refresh forwards to the backend platform (full re-emission)',
      () {
    final io = FakeStdio()..columns = 120;
    final platform = _RefreshRecordingPlatform();
    final backend = NotcursesBackend.forTesting(io: io, platform: platform);
    final screen = Screen.withBackend(
      backend: backend,
      io: io,
      layout: ScreenLayout.fromSize(120, 40, split: false),
    );

    expect(platform.refreshCalls, 0);
    screen.refresh();
    expect(platform.refreshCalls, 1,
        reason: 'Screen.refresh must reach notcurses_refresh so the full '
            'rasterized frame is re-emitted after a resize');
  });

  test('refresh is a no-op in passthrough mode', () {
    final io = FakeStdio()..columns = 120;
    final screen = Screen.passthrough(io);
    screen.refresh(); // must not throw
  });

  test('same-size resize still re-emits the complete retained frame', () {
    final io = FakeStdio()..columns = 120;
    final platform = _RefreshRecordingPlatform();
    final backend = NotcursesBackend.forTesting(io: io, platform: platform);
    final layout = ScreenLayout.fromSize(120, 40, split: false);
    final screen = Screen.withBackend(backend: backend, io: io, layout: layout);
    screen.resize(layout);
    expect(platform.refreshCalls, 1);
    expect(platform.calls.last, 'refresh');
    expect(platform.calls, contains('render'));
  });

  test('refresh presents pending plane changes before replaying the raster',
      () {
    final io = FakeStdio()..columns = 120;
    final platform = _RefreshRecordingPlatform();
    final backend = NotcursesBackend.forTesting(io: io, platform: platform);
    backend.writeText('new frame');
    backend.refresh();
    expect(platform.calls, ['render', 'refresh']);
    expect(backend.gridDirty, false);
  });

  test('resize refresh waits for the enclosing frame to finish', () {
    final io = FakeStdio()..columns = 120;
    final platform = _RefreshRecordingPlatform();
    final backend = NotcursesBackend.forTesting(io: io, platform: platform);
    final layout = ScreenLayout.fromSize(120, 40, split: false);
    final screen = Screen.withBackend(backend: backend, io: io, layout: layout);
    screen.frame(() {
      screen.resize(layout);
      expect(platform.refreshCalls, 0);
      backend.writeText('final frame change');
    });
    expect(platform.refreshCalls, 1);
    expect(platform.calls.last, 'refresh');
    expect(backend.gridDirty, false);
  });

  test('NotcursesBackend.refresh re-parks the hardware cursor', () {
    final io = FakeStdio()..columns = 120;
    final platform = _RefreshRecordingPlatform();
    final backend = NotcursesBackend.forTesting(io: io, platform: platform);

    backend.parkCursor(7, 3);
    backend.refresh();
    expect(platform.refreshCalls, 1);
    expect(platform.lastCursorEnable, (7, 3),
        reason: 'after a full re-emission the cursor must be re-parked at '
            'the editor position, not left wherever the refresh raster left '
            'it');
  });
}

class _RefreshRecordingPlatform implements NotcursesPlatform {
  final calls = <String>[];
  int refreshCalls = 0;
  (int, int)? lastCursorEnable;

  @override
  bool refresh() {
    calls.add('refresh');
    refreshCalls++;
    return true;
  }

  @override
  void cursorEnable(int y, int x) => lastCursorEnable = (y, x);

  // -- Unused by these tests ----------------------------------------------

  @override
  BackendSurface createSurface(Rect bounds) => throw UnimplementedError();
  @override
  InputBackend createInputBackend() => throw UnimplementedError();
  @override
  void putStrYX(int row, int col, String text) {}
  @override
  void setStyles(int stylebits) {}
  @override
  void setFgRGB(int hex) {}
  @override
  void setBgRGB(int hex) {}
  @override
  void setFgDefault() {}
  @override
  void setBgDefault() {}
  @override
  bool render() {
    calls.add('render');
    return true;
  }

  @override
  void cursorDisable() {}
  @override
  void stop() {}
  @override
  int paletteSize() => 256;
  @override
  int planeColumns() => 120;
  @override
  int? defaultBackground() => null;
  @override
  void writeRawToTty(String s) {}
  @override
  nc.Plane? get plane => null;
  @override
  nc.NotCurses? get notc => null;
}
