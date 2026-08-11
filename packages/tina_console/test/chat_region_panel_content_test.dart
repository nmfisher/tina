import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

/// Chat-coupled tests for the panel-abstraction split. These pin the behavior
/// that used to live inside `ConversationPanel` and now lives in the
/// [ChatRegionPanelContent] adapter: input-row reservation and the
/// history-preservation invariant (cycling focus must not eat scrollback). The
/// chrome frame is exercised only as the holder of the `interior` rect the
/// adapter positions into.
void main() {
  late FakeStdio io;
  late Screen screen;
  late VirtualTerminal vt;

  setUp(() {
    io = FakeStdio()..columns = 100;
    final layout = ScreenLayout.fromSize(100, 24, split: true, drawInfoFrame: false);
    screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
    vt = VirtualTerminal(width: 100, height: 24);
    screen.redrawFrame();
    vt.feed(io.written.toString());
    io.written.clear();
  });

  // A panel sized to sit entirely inside the info column, like the coordinator
  // lays them out. Interior: rows 6..9, cols 69..94 (height 4, width 26).
  const panelRect = Rect(row: 5, col: 68, width: 28, height: 6);

  // Build a frame + detached-chat adapter, lay the chat into the interior, and
  // return both for assertions.
  (PanelFrame frame, ChatRegionPanelContent content, ScrollingTextRegion chat)
      _panelWithChat(String label, Rect rect) {
    final chat = ScrollingTextRegion(screen, bounds: screen.layout.info)
      ..detach();
    final content = ChatRegionPanelContent(chat);
    final frame = PanelFrame(
      screen: screen,
      label: label,
      conversationId: 'c1',
    )..setReservesInput(true);
    frame.setOuter(rect);
    content.fit(frame.interior, reserveInputRow: frame.reservesInput);
    // Mirror the coordinator's _layOutContent: attach a freshly-laid-out chat
    // (the detached region buffers until attached, exactly as setOuter used to).
    if (content.isDetached) content.attach();
    return (frame, content, chat);
  }

  group('ChatRegionPanelContent (input-row reservation)', () {
    test('content written to the wrapped region lands in the interior', () {
      final (_, _, chat) = _panelWithChat('m', panelRect);
      vt.feed(io.written.toString()); // border draw
      io.written.clear();

      chat.write('hello world\n');
      vt.feed(io.written.toString()); // content

      // Content is bottom-aligned within the interior (rows 6..9, cols 69..94).
      var foundRow = -1;
      for (var r = 6; r <= 9; r++) {
        if (vt.rowText(r).substring(69, 94).contains('hello world')) {
          foundRow = r;
        }
      }
      expect(foundRow, greaterThan(0), reason: 'content must render interior');
      // The border cells on that content row are untouched (still side bars).
      expect(vt.charAt(foundRow, 68), '│');
      expect(vt.charAt(foundRow, 95), '│');
    });

    test('reservation reserves the input row without shrinking the buffer', () {
      final (frame, content, chat) = _panelWithChat('m', panelRect);
      // Interior rows 6..9 (height 4). The adapter fit set reservesInput → the
      // chat is positioned at full height with a bottom inset.
      expect(chat.bounds.height, 4);

      // Fill the interior so every row carries content.
      chat.write('L0\nL1\nL2\nL3');
      vt.feed(io.written.toString());
      io.written.clear();

      // Releasing then re-reserving the input row is the focus-cycle the
      // history regression hinges on; here we assert the buffer is preserved
      // through the toggle. Flipping the frame's reservation flag only updates
      // the flag — the adapter's fit() applies it to the chat, exactly as the
      // coordinator does, so refit after each toggle.
      frame.setReservesInput(false);
      content.fit(frame.interior, reserveInputRow: frame.reservesInput);
      vt.feed(io.written.toString());
      expect(chat.bounds.height, 4); // unchanged
      expect(chat.bottomInset, 0);

      frame.setReservesInput(true);
      content.fit(frame.interior, reserveInputRow: frame.reservesInput);
      vt.feed(io.written.toString());
      // The buffer height is unchanged (no rows dropped)...
      expect(chat.bounds.height, 4);
      expect(chat.bottomInset, 1);
      // ...but the bottom interior row (the input row) is cleared, and the
      // oldest row scrolls up out of view while the input is shown.
      expect(vt.rowText(9).substring(69, 94).trim(), isEmpty,
          reason: 'input row cleared');
      expect(vt.rowText(6).contains('L1'), isTrue);
      expect(vt.rowText(8).contains('L3'), isTrue);
    });
  });

  group('history preservation (the focus-cycle regression)', () {
    test('cycling focus away and back keeps the oldest message', () {
      // Regression: the panel used to resize (and reconcile) the chat buffer.
      // Grow-on-blur / shrink-on-focus each cycle permanently dropped the
      // oldest buffered row, so cycling away and back ate history — at least
      // the user's first message. Reserving via a bottom inset (the adapter's
      // job) instead leaves the buffer intact.
      final (frame, content, chat) = _panelWithChat('m', panelRect);
      // Three lines fill the reserved usable area exactly (no overflow
      // scroll), so the only thing that could drop "first" is the reserve
      // toggle itself.
      chat.write('first\nL1\nL2');
      vt.feed(io.written.toString());
      io.written.clear();

      // Cycle away (release the input row) then back (reserve it again).
      frame.setReservesInput(false);
      content.fit(frame.interior, reserveInputRow: frame.reservesInput);
      vt.feed(io.written.toString());
      io.written.clear();
      frame.setReservesInput(true);
      content.fit(frame.interior, reserveInputRow: frame.reservesInput);
      vt.feed(io.written.toString());
      io.written.clear();

      // The first message must still be in the buffer — rendered somewhere in
      // the panel interior after the round trip.
      final interior = [for (var r = 6; r <= 9; r++) vt.rowText(r)].join('\n');
      expect(interior.contains('first'), isTrue,
          reason: 'first message survives a focus cycle');
    });

    test('a content write on an interior row does not clobber the comet head', () {
      final (frame, _, chat) = _panelWithChat('m', panelRect);
      addTearDown(frame.dispose);
      frame.setBusy(true);
      // Intentionally NOT clearing: the border + write must both be in the
      // buffer. The write lands on the interior (bottom-aligned, row 9); the
      // head on the top/bottom rails is untouched (writes are clipped to the
      // interior).
      chat.write('X');
      vt.feed(io.written.toString());

      int? headCol(int row) {
        for (var c = 68; c < 96; c++) {
          if (vt.charAt(row, c) == '━') return c;
        }
        return null;
      }

      // The input row (row 9) is reserved, so content bottom-aligns to the last
      // usable interior row (row 8). The comet heads on the top/bottom rails
      // (rows 5/10) are untouched — the write is clipped to the interior.
      expect(headCol(5), isNotNull, reason: 'top-rail head survives the write');
      expect(headCol(10), isNotNull, reason: 'bottom-rail head survives the write');
      expect(vt.rowText(8).contains('X'), isTrue, reason: 'write lands in interior');
      // Row 9's interior (between the side borders) stays clear for the input
      // line — only the side-border cells ('│') of the chrome remain.
      expect(vt.rowText(9).substring(69, 94).trim(), isEmpty,
          reason: 'reserved input row interior stays clear');
    });
  });

  // Regression coverage for the reported overflow: text spilling outside a
  // spawned panel's borders (right border, bottom, sides). Clipping is by
  // convention — each region passes maxCols: bounds.width; there is no central
  // clip — so these assert the invariant directly: a character written into a
  // fitted panel must never land outside the frame's outer rect.
  group('content containment (overflow regression)', () {
    // Assert no cell holding [ch] lies outside [outer]. Scans the whole grid so
    // a leak in any direction (right border, bottom, neighbour panel) fails.
    void expectContained(String ch, Rect outer) {
      for (var r = 0; r < vt.height; r++) {
        for (var c = 0; c < vt.width; c++) {
          if (vt.charAt(r, c) == ch) {
            final inside = c >= outer.col &&
                c < outer.col + outer.width &&
                r >= outer.row &&
                r < outer.row + outer.height;
            if (!inside) {
              fail("'$ch' at ($r,$c) is outside the panel outer rect $outer");
            }
          }
        }
      }
    }

    test('a long line wraps inside the panel, never crossing its right border',
        () {
      final (_, _, chat) = _panelWithChat('m', panelRect);
      vt.feed(io.written.toString()); // border draw
      io.written.clear();

      // Far wider than the 26-wide interior.
      chat.write('${'z' * 200}\n');
      vt.feed(io.written.toString());

      expectContained('z', panelRect);
      // The side borders on every interior row are intact.
      for (var r = panelRect.row + 1; r < panelRect.row + panelRect.height - 1;
          r++) {
        expect(vt.charAt(r, panelRect.col), '│',
            reason: 'left border survives a long write on row $r');
        expect(vt.charAt(r, panelRect.col + panelRect.width - 1), '│',
            reason: 'right border survives a long write on row $r');
      }
    });

    test('more lines than the interior height scroll inside, never past the bottom',
        () {
      final (_, _, chat) = _panelWithChat('m', panelRect);
      vt.feed(io.written.toString());
      io.written.clear();

      // The interior is 4 rows; write far more.
      for (var i = 0; i < 50; i++) {
        chat.write('y$i\n');
      }
      vt.feed(io.written.toString());

      expectContained('y', panelRect);
      // Bottom border intact.
      final bottom = panelRect.row + panelRect.height - 1;
      expect(vt.charAt(bottom, panelRect.col), '└');
      expect(vt.charAt(bottom, panelRect.col + panelRect.width - 1), '┘');
    });

    test('after the panel is narrowed, new writes clip inside the narrower rect',
        () {
      // Start wide (the right column interior), as spawned chats are born.
      const wide = Rect(row: 5, col: 68, width: 28, height: 6);
      final (frame, content, chat) = _panelWithChat('m', wide);
      vt.feed(io.written.toString());
      io.written.clear();

      // Narrow the panel in place (same origin, smaller width) — a resize that
      // tiles a sibling in. Then write fresh content wider than the new
      // interior; it must wrap to the new width, not the old one.
      const narrow = Rect(row: 5, col: 68, width: 18, height: 6);
      frame.setOuter(narrow);
      content.fit(frame.interior, reserveInputRow: frame.reservesInput);
      vt.feed(io.written.toString());
      io.written.clear();

      chat.write('${'q' * 60}\n');
      vt.feed(io.written.toString());

      expectContained('q', narrow);
    });

    // The core overflow reproduction: when the panel is repositioned (not just
    // resized) and re-fit, the live BackendSurface must move with it. Today
    // ChatRegionPanelContent.fit calls setBottomInset (which sizes the surface
    // to the CURRENT/old bounds) before setBoundsOverride (which updates the
    // bounds value but never repositions the surface), so the surface is left
    // at the old origin and subsequent writes render at the old position —
    // spilling across the border into whatever now occupies that space.
    test('after the panel is moved, the surface (and writes) follow it', () {
      const wide = Rect(row: 5, col: 68, width: 28, height: 6);
      final (frame, content, chat) = _panelWithChat('m', wide);
      vt.feed(io.written.toString());
      io.written.clear();

      // Reposition + shrink the panel, then re-fit (the relayContent path on a
      // resize / sibling-tile).
      const moved = Rect(row: 5, col: 80, width: 18, height: 6);
      frame.setOuter(moved);
      content.fit(frame.interior, reserveInputRow: frame.reservesInput);
      vt.feed(io.written.toString());
      io.written.clear();

      // 'Z' is distinct from the panel label/chrome so the scan isn't fooled
      // by stale chrome left at the old position (the real coordinator clears
      // the column before layout; this isolated test does not).
      chat.write('Z\n');
      vt.feed(io.written.toString());

      // The write must land inside the moved rect — not at the old col-68
      // origin where a stale surface would put it.
      expectContained('Z', moved);
      // And the surface itself must track the new position. (Its height is the
      // interior height minus the reserved input row — the input row lives on
      // the standard plane, below the surface.)
      expect(chat.surface!.bounds.row, frame.interior.row);
      expect(chat.surface!.bounds.col, frame.interior.col);
      expect(chat.surface!.bounds.width, frame.interior.width);
    });
  });

  // The frame-owns-canvas seam (Phase 4): the PanelFrame owns the chat's
  // BackendSurface and the region borrows it, so geometry flows one way.
  // Gated by ownsCanvas; production keeps it off (legacy) until Phase 5.
  group('frame-owns-canvas seam', () {
    test('the region borrows the frame surface and bounds derive from it', () {
      const rect = Rect(row: 5, col: 68, width: 28, height: 6);
      final chat =
          ScrollingTextRegion(screen, bounds: screen.layout.info)..detach();
      final content = ChatRegionPanelContent(chat);
      final frame = PanelFrame(
        screen: screen,
        label: 'p',
        conversationId: 'c1',
        ownsCanvas: true,
      )..setReservesInput(false);
      frame.setOuter(rect);

      // Mimic the coordinator's _positionContent: bind the frame surface, then
      // fit + attach. reservesInput is false so the surface covers the full
      // interior (the input-row-as-surface-inset is a Phase 5 concern).
      content.bindSurface(frame.surface);
      content.fit(frame.interior, reserveInputRow: false);
      if (content.isDetached) content.attach();
      vt.feed(io.written.toString());
      io.written.clear();

      // The region now borrows the frame's surface; bounds come from it.
      expect(frame.surface, isNotNull);
      expect(chat.surface, same(frame.surface));
      expect(chat.hasBoundSurface, isTrue);
      expect(chat.bounds, frame.surface!.bounds);

      // Content written through the region lands inside the frame interior.
      chat.write('Z' * 200);
      vt.feed(io.written.toString());
      for (var r = 0; r < vt.height; r++) {
        for (var c = 0; c < vt.width; c++) {
          if (vt.charAt(r, c) == 'Z') {
            final insideRect = Rect(
              row: rect.row + 1,
              col: rect.col + 1,
              width: rect.width - 2,
              height: rect.height - 2,
            );
            expect(c >= insideRect.col && c < insideRect.col + insideRect.width,
                isTrue,
                reason: "'Z' at col $c escapes the frame interior");
          }
        }
      }
    });

    test('with the input row reserved, content fills the surface above it', () {
      // The realistic spawned-panel case: reservesInput true. The frame sizes
      // the surface to interior minus the input row; the region leaves
      // _bottomInset at 0 (the inset is structural), so content uses the whole
      // surface rather than wasting a row.
      const rect = Rect(row: 5, col: 68, width: 28, height: 6);
      final chat =
          ScrollingTextRegion(screen, bounds: screen.layout.info)..detach();
      final content = ChatRegionPanelContent(chat);
      final frame = PanelFrame(
        screen: screen,
        label: 'p',
        conversationId: 'c1',
        ownsCanvas: true,
      )..setReservesInput(true);
      frame.setOuter(rect);

      content.bindSurface(frame.surface);
      content.fit(frame.interior, reserveInputRow: true);
      if (content.isDetached) content.attach();
      vt.feed(io.written.toString());
      io.written.clear();

      // Surface is the interior minus the reserved input row.
      expect(frame.surface!.bounds.height, frame.interior.height - 1);

      // Fill every usable row; all of it stays inside the frame.
      chat.write('L0\nL1\nL2\nL3');
      vt.feed(io.written.toString());
      for (var r = 0; r < vt.height; r++) {
        for (var c = 0; c < vt.width; c++) {
          final ch = vt.charAt(r, c);
          if (ch == 'L') {
            expect(c >= rect.col + 1 && c < rect.col + rect.width - 1, isTrue,
                reason: "'L' at ($r,$c) escapes the frame");
            expect(r >= rect.row + 1 && r < rect.row + rect.height - 1, isTrue,
                reason: "'L' at ($r,$c) escapes the frame");
          }
        }
      }
    });
  });

  group('PanelFrame.handleEvent (scrollback routing)', () {
    (PanelFrame, ChatRegionPanelContent, ScrollingTextRegion) panel() =>
        _panelWithChat('m', panelRect);

    test('PgUp/PgDn call onScroll (±1 page)', () {
      final (frame, _, _) = panel();
      final pages = <int>[];
      frame.onScroll = pages.add;
      expect(frame.handleEvent(ArrowKey(ArrowDirection.pageUp)), isTrue);
      expect(
          frame.handleEvent(ArrowKey(ArrowDirection.pageDown)), isTrue);
      expect(pages, [-1, 1]);
    });

    test('the mouse wheel calls onWheel — 3 rows per notch, never the editor',
        () {
      final (frame, _, _) = panel();
      final rows = <int>[];
      frame.onWheel = rows.add;
      expect(frame.handleEvent(ScrollEvent(up: true)), isTrue);
      expect(frame.handleEvent(ScrollEvent(up: false)), isTrue);
      expect(rows, [-3, 3]);
    });

    test('an unwired wheel falls through (not consumed by the panel)', () {
      final (frame, _, _) = panel();
      expect(frame.handleEvent(ScrollEvent(up: true)), isFalse);
    });
  });
}
