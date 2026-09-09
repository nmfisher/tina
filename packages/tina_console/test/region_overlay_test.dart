import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

void main() {
  group('OverlayRegion', () {
    late _FrameStdio io;
    late Screen screen;
    late VirtualTerminal vt;
    late ScreenLayout layout;

    setUp(() {
      io = _FrameStdio();
      layout = ScreenLayout.fromSize(100, 24);
      screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
      vt = VirtualTerminal(width: 100, height: 24);
      screen.redrawFrame();
      vt.feed(io.written.toString());
      io.written.clear();
      io.frames.clear();
    });

    test('update moves and shrinks in one presentation, clearing old bounds',
        () {
      final overlay = OverlayRegion(screen, Rect.empty);
      addTearDown(overlay.dispose);
      overlay.update(
        bounds: const Rect(row: 5, col: 5, width: 12, height: 3),
        lines: ['first', 'second', 'third'],
      );
      expect(io.frames, hasLength(1));
      vt.feed(io.frames.single);
      io.frames.clear();

      overlay.update(
        bounds: const Rect(row: 6, col: 7, width: 8, height: 2),
        lines: ['new', 'last'],
      );
      expect(io.frames, hasLength(1),
          reason: 'cleanup, replacement, and border repairs must batch');
      vt.feed(io.frames.single);
      expect(vt.rowText(5).substring(5, 17).trim(), isEmpty);
      expect(vt.rowText(6).substring(5, 17), '  new       ');
      expect(vt.rowText(7).substring(5, 17), '  last      ');
    });

    test('show and hide each present once and join an enclosing frame', () {
      final overlay = OverlayRegion(
          screen, const Rect(row: 5, col: 5, width: 12, height: 3));
      addTearDown(overlay.dispose);
      screen.frame(() {
        overlay.show(['one', 'two', 'three']);
        overlay.show(['final']);
        expect(io.frames, isEmpty);
      });
      expect(io.frames, hasLength(1));
      vt.feed(io.frames.single);
      expect(vt.rowText(5).substring(5, 17).trim(), 'final');
      expect(vt.rowText(6).substring(5, 17).trim(), isEmpty);
      io.frames.clear();

      overlay.hide();
      expect(io.frames, hasLength(1));
      expect(overlay.isVisible, isFalse);
      vt.feed(io.frames.single);
      expect(vt.rowText(5).substring(5, 17).trim(), isEmpty);
      io.frames.clear();
      overlay.hide();
      expect(io.frames, isEmpty);
    });

    test('update to offscreen bounds dismisses the old overlay atomically', () {
      final overlay = OverlayRegion(
          screen, const Rect(row: 5, col: 5, width: 12, height: 3));
      addTearDown(overlay.dispose);
      overlay.show(['one', 'two', 'three']);
      vt.feed(io.frames.single);
      io.frames.clear();
      overlay.update(
        bounds: const Rect(row: 30, col: 5, width: 12, height: 3),
        lines: ['offscreen'],
      );
      expect(io.frames, hasLength(1));
      expect(overlay.isVisible, isFalse);
      vt.feed(io.frames.single);
      for (var row = 5; row < 8; row++) {
        expect(vt.rowText(row).substring(5, 17).trim(), isEmpty);
      }
    });

    test('command navigation reuses its surface and presents once per key',
        () async {
      var created = 0;
      final counting = _CountingScreen(
        io: io,
        layout: layout,
        ansi: AnsiCapable.yes,
        onCreate: () => created++,
      );
      final picker =
          CompletionPicker.commandPicker(counting, provider: _Commands());
      addTearDown(picker.dispose);
      picker.open(0);
      await picker.refresh('/', 1);
      final initialSurfaces = created;
      io.frames.clear();

      for (final navigate in [picker.navigateDown, picker.navigateUp]) {
        navigate();
        expect(created, initialSurfaces,
            reason: 'selection changes must preserve the existing surface');
        expect(io.frames, hasLength(1));
        expect(io.frames.single, contains('/help'));
        expect(io.frames.single, contains('/quit'));
        io.frames.clear();
      }
      expect(picker.accept('/', 1)!.text, '/help ');
    });

    test('show writes lines, hide clears and repaints borders', () {
      final overlay = OverlayRegion(
        screen,
        const Rect(row: 10, col: 5, width: 20, height: 3),
      );
      overlay.show(['line A', 'line B', 'line C']);
      vt.feed(io.written.toString());
      expect(vt.rowText(10).substring(5, 11), 'line A');
      expect(vt.rowText(11).substring(5, 11), 'line B');
      expect(vt.rowText(12).substring(5, 11), 'line C');

      overlay.hide();
      vt.feed(io.written.toString());
      for (var r = 10; r <= 12; r++) {
        final t = vt.rowText(r).substring(5, 25);
        expect(t.trim(), isEmpty, reason: 'row $r should be blank');
      }
      // Info-box borders intact.
      for (var r = 10; r <= 12; r++) {
        vt.assertBorders(
            r, layout.infoLeftCol, layout.infoRightCol, layout.infoRightCol);
      }
      overlay.dispose();
    });

    test('show clips lines longer than width', () {
      final overlay = OverlayRegion(
        screen,
        const Rect(row: 5, col: 5, width: 6, height: 1),
      );
      overlay.show(['HELLO WORLD']);
      vt.feed(io.written.toString());
      final row = vt.rowText(5);
      expect(row.substring(5, 11), 'HELLO ');
      expect(row.substring(11, 12), isNot('W'));
      overlay.dispose();
    });

    test('reposition hides old rectangle', () {
      final overlay = OverlayRegion(
        screen,
        const Rect(row: 5, col: 5, width: 10, height: 1),
      );
      overlay.show(['hi']);
      overlay.reposition(const Rect(row: 8, col: 5, width: 10, height: 1));
      overlay.show(['ok']);
      vt.feed(io.written.toString());

      // Old row blanked.
      final oldRow = vt.rowText(5).substring(5, 15);
      expect(oldRow.trim(), isEmpty);
      // New row has content.
      final newRow = vt.rowText(8);
      expect(newRow.substring(5, 7), 'ok');
      overlay.dispose();
    });

    test('extra rows from previous show are erased', () {
      final overlay = OverlayRegion(
        screen,
        const Rect(row: 10, col: 5, width: 20, height: 3),
      );
      overlay.show(['a', 'b', 'c']);
      overlay.show(['only-line']);
      vt.feed(io.written.toString());
      // Row 10 has new content.
      expect(vt.rowText(10).substring(5, 14), 'only-line');
      // Rows 11 and 12 erased.
      expect(vt.rowText(11).substring(5, 25).trim(), isEmpty);
      expect(vt.rowText(12).substring(5, 25).trim(), isEmpty);
      overlay.dispose();
    });

    test('clips bounds to screen', () {
      // Position partially off the bottom — should clip to fit.
      final overlay = OverlayRegion(
        screen,
        const Rect(row: 22, col: 5, width: 10, height: 5),
      );
      // Bounds are clipped so we don't write into the bottom border row.
      expect(overlay.bounds.bottom <= layout.height - 1, isTrue);
      overlay.dispose();
    });

    test('same-bounds updates and reposition reuse the surface', () {
      // Destroying + recreating the plane per show made notcurses rasterize
      // frames without the overlay — a visible flash on every arrow key of a
      // picker that re-renders per event.
      var created = 0;
      final counting = _CountingScreen(
        io: io,
        layout: layout,
        ansi: AnsiCapable.yes,
        onCreate: () => created++,
      );
      final overlay = OverlayRegion(
        counting,
        const Rect(row: 6, col: 4, width: 12, height: 3),
      );
      overlay.show(['one']);
      overlay.show(['two']);
      overlay.show(['three']);
      expect(created, 1, reason: 'same-bounds shows must reuse the live plane');

      overlay.update(
        bounds: const Rect(row: 6, col: 4, width: 12, height: 3),
        lines: ['updated'],
      );
      overlay.reposition(const Rect(row: 6, col: 4, width: 12, height: 3));
      expect(overlay.isVisible, isTrue);
      expect(created, 1);

      overlay.reposition(const Rect(row: 12, col: 4, width: 12, height: 3));
      overlay.show(['moved']);
      expect(created, 2, reason: 'a bounds change must recycle the plane');

      overlay.hide();
      overlay.show(['again']);
      expect(created, 3, reason: 'hide destroys the surface; show recreates');
      overlay.dispose();
    });
  });
}

class _FrameStdio extends FakeStdio {
  final frames = <String>[];

  @override
  void write(String s) {
    frames.add(s);
    super.write(s);
  }
}

class _Commands implements CompletionProvider {
  @override
  Future<List<String>> complete(String query) async => ['/help', '/quit'];
}

class _CountingScreen extends Screen {
  final void Function() onCreate;
  _CountingScreen({
    required super.io,
    required super.layout,
    required super.ansi,
    required this.onCreate,
  });

  @override
  BackendSurface createSurface(Rect bounds) {
    onCreate();
    return super.createSurface(bounds);
  }
}
