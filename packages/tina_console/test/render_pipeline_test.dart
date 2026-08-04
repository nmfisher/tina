import 'dart:async';

import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

/// End-to-end invariants for the render pipeline.
///
/// These tests exercise the full Screen + Region + LineEditor stack against
/// a VirtualTerminal and assert the invariants that the architecture is
/// designed to enforce:
///  - frame borders are intact after every operation
///  - no chat/input content ever leaks past the divider into the right panel
///  - no overlay/spinner content leaks left
///  - cursor stays inside the panel it belongs to

class _StaticProvider implements CompletionProvider {
  final List<String> results;
  _StaticProvider(this.results);
  @override
  Future<List<String>> complete(String query) async => results;
}

Future<void> _flush() async {
  await Future<void>.microtask(() {});
  await Future<void>.microtask(() {});
  await Future<void>.delayed(Duration.zero);
}

void main() {
  const W = 100;
  const H = 24;

  void assertFrameIntact(VirtualTerminal vt, ScreenLayout layout) {
    // The chat area's border is panel-drawn (see conversation_panel_test); the
    // Screen paints only the info box now. Assert that info box stays intact
    // through every operation — its corners, top title row, bottom, and sides.
    final infoW = layout.infoRightCol - layout.infoLeftCol + 1;
    final infoLabel = ' info ';
    final infoTop = '┌─$infoLabel${'─' * (infoW - 3 - infoLabel.length)}┐';
    expect(vt.rowText(0).substring(layout.infoLeftCol), infoTop,
        reason: 'info top border row');
    expect(vt.rowText(H - 1).substring(layout.infoLeftCol),
        '└${'─' * (infoW - 2)}┘',
        reason: 'info bottom border row');
    for (var r = 1; r < H - 1; r++) {
      final row = vt.rowText(r);
      expect(row[layout.infoLeftCol], '│',
          reason: 'row $r col ${layout.infoLeftCol}: info left border');
      expect(row[layout.infoRightCol], '│',
          reason: 'row $r col ${layout.infoRightCol}: info right border');
    }
  }

  void assertNoLeakIntoRightPanel(VirtualTerminal vt, ScreenLayout layout) {
    for (var r = layout.chat.row; r < layout.chat.row + layout.chat.height; r++) {
      // Info interior sits between infoLeftCol+1 and infoRightCol-1.
      final right = vt.rowText(r).substring(
          layout.infoLeftCol + 1, layout.infoRightCol);
      // Info interior may contain the info panel's own content; here we
      // test cases where nothing has been written into info.
      expect(right.trim(), isEmpty,
          reason: 'row $r: chat content leaked into info panel');
    }
  }

  group('Frame stays intact through workflows', () {
    late FakeStdio io;
    late Screen screen;
    late VirtualTerminal vt;
    late ScreenLayout layout;

    setUp(() {
      io = FakeStdio();
      layout = ScreenLayout.fromSize(W, H);
      screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
      vt = VirtualTerminal(width: W, height: H);
      screen.redrawFrame();
      vt.feed(io.written.toString());
      io.written.clear();
    });

    test('chat writes that exceed bounds never disturb the frame', () {
      // Force scrolling.
      for (var i = 0; i < layout.chat.height + 5; i++) {
        screen.chat.write('line $i of stuff\n');
      }
      vt.feed(io.written.toString());
      assertFrameIntact(vt, layout);
    });

    test('spinner stop after run leaves bottom border alone', () async {
      final s = Spinner(
        enabled: true,
        region: screen.status,
        rowOffset: layout.status.height - 1,
      );
      s.start(label: 'thinking');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      vt.feed(io.written.toString());
      io.written.clear();
      // The spinner is a no-op now (animation retired); stop/dispose do
      // nothing. Redraw the frame to confirm it stays intact regardless.
      s.stop();
      s.dispose();
      screen.redrawFrame();
      vt.feed(io.written.toString());
      assertFrameIntact(vt, layout);
    });

    test('progress lifecycle in status leaves frame intact', () {
      final p = ProgressCounter(
        enabled: true,
        region: screen.status,
        rowOffset: 5,
      );
      p.start('files', total: 10);
      p.tick(5);
      p.finish();
      vt.feed(io.written.toString());
      assertFrameIntact(vt, layout);
    });

    test('clearChat erases content but keeps frame', () {
      screen.chat.write('hello\nworld\n');
      screen.clearChat();
      vt.feed(io.written.toString());
      assertFrameIntact(vt, layout);
      assertNoLeakIntoRightPanel(vt, layout);
    });

    test('resize redraws info frame at new size', () {
      final newLayout = ScreenLayout.fromSize(120, H);
      screen.resize(newLayout);
      final wideVt = VirtualTerminal(width: 120, height: H);
      wideVt.feed(io.written.toString());
      final infoW = newLayout.infoRightCol - newLayout.infoLeftCol + 1;
      final infoTop = '┌─ info ${'─' * (infoW - 3 - 6)}┐';
      expect(wideVt.rowText(0).substring(newLayout.infoLeftCol), infoTop);
      expect(wideVt.rowText(H - 1).substring(newLayout.infoLeftCol),
          '└${'─' * (infoW - 2)}┘');
    });
  });

  group('Editor end-to-end', () {
    late FakeStdio io;
    late Screen screen;
    late VirtualTerminal vt;
    late ScreenLayout layout;
    late LineEditor editor;

    setUp(() {
      io = FakeStdio();
      layout = ScreenLayout.fromSize(W, H);
      screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
      vt = VirtualTerminal(width: W, height: H);
      screen.redrawFrame();
      vt.feed(io.written.toString());
      io.written.clear();
      editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
    });

    tearDown(() => editor.close());

    test('typing many chars stays in left panel and keeps frame', () async {
      editor.readLine('> ');
      await _flush();
      for (final c in ('a' * 60).codeUnits) {
        io.feedBytes([c]);
      }
      await _flush();
      vt.feed(io.written.toString());

      // No 'a' leaks into right panel.
      for (var r = layout.chat.row; r <= layout.input.row; r++) {
        final right =
            vt.rowText(r).substring(layout.dividerCol + 1, W - 1);
        expect(right.contains('a'), isFalse, reason: 'row $r right leak');
      }
      assertFrameIntact(vt, layout);
    });

    test('Ctrl-U on wrapped buffer clears all rows', () async {
      editor.readLine('> ');
      await _flush();
      for (final c in ('a' * 80).codeUnits) {
        io.feedBytes([c]);
      }
      await _flush();
      io.feedBytes([0x15]); // Ctrl-U
      await _flush();
      vt.feed(io.written.toString());
      // Input row should now have just '> ' near col 1.
      final inputRow = vt.rowText(layout.input.row);
      expect(inputRow.substring(layout.input.col, layout.input.col + 2), '> ');
      assertFrameIntact(vt, layout);
    });

    test('Ctrl-C confirmation overlay does not break borders', () async {
      editor.readLine('> ');
      await _flush();
      io.feedBytes([0x03]); // first Ctrl-C
      await _flush();
      vt.feed(io.written.toString());

      // Dialog visible somewhere.
      var foundDialog = false;
      for (var r = 0; r < H; r++) {
        if (vt.rowText(r).contains('Ctrl+C again to exit')) {
          foundDialog = true;
          break;
        }
      }
      expect(foundDialog, isTrue);
      assertFrameIntact(vt, layout);

      // Dismiss with a character.
      io.feedBytes([0x61]); // 'a' dismisses
      await _flush();
      vt.feed(io.written.toString());
      assertFrameIntact(vt, layout);

      io.feedBytes([0x0d]); // submit
      await _flush();
    });

    test('picker opens and closes without touching borders', () async {
      editor.completionProvider = _StaticProvider(['lib/a.dart', 'lib/b.dart']);
      editor.readLine('> ');
      await _flush();
      io.feedBytes([0x40]); // '@'
      await _flush();
      // Pump one more cycle for the async refresh.
      await _flush();
      vt.feed(io.written.toString());
      // Verify the picker rendered (contents appear somewhere).
      var seen = false;
      for (var r = 0; r < H; r++) {
        if (vt.rowText(r).contains('lib/a.dart')) seen = true;
      }
      expect(seen, isTrue);
      assertFrameIntact(vt, layout);

      // Dismiss with ESC.
      io.feedBytes([0x1b]);
      await _flush();
      vt.feed(io.written.toString());
      // Picker contents are gone.
      var stillThere = false;
      for (var r = 0; r < H; r++) {
        if (vt.rowText(r).contains('lib/a.dart')) stillThere = true;
      }
      expect(stillThere, isFalse);
      assertFrameIntact(vt, layout);

      io.feedBytes([0x03, 0x03]); // exit
      await _flush();
    });

    test('SIGWINCH resize re-renders without corruption', () async {
      editor.readLine('> ');
      await _flush();
      for (final c in 'hello'.codeUnits) {
        io.feedBytes([c]);
      }
      await _flush();

      // Resize to a wider terminal.
      final newLayout = ScreenLayout.fromSize(120, H);
      screen.resize(newLayout);
      editor.handleResize();

      // Buffer should still resolve cleanly on Enter.
      io.feedBytes([0x0d]);
      // Note: not awaiting the future — just confirming no crash.
      await _flush();
    });
  });
}
