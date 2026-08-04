import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

/// Scrollback (PgUp / PgDn) coverage for [ScrollingTextRegion] and the
/// [PanelFrame] badge / key-claim. The retention model keeps the visible
/// window ([_rows]) byte-identical to the pre-scrollback behaviour at
/// offset 0 (pinned by the rest of the suite); these tests cover the
/// scroll-offset machinery that only engages once the user pages up.
///
/// Geometry is kept tiny and explicit: a 4-row region (usable height 4, no
/// input inset) so the "window vs. history" boundary is obvious.
void main() {
  late FakeStdio io;
  late Screen screen;
  late VirtualTerminal vt;

  setUp(() {
    io = FakeStdio()..columns = 40;
    final layout = ScreenLayout.fromSize(40, 12, split: false, drawInfoFrame: false);
    screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
    vt = VirtualTerminal(width: 40, height: 12);
    screen.redrawFrame();
    vt.feed(io.written.toString());
    io.written.clear();
  });

  // A 4-row region at the top-left. usableHeight == 4 (no bottom inset).
  ScrollingTextRegion _region() {
    final r = ScrollingTextRegion(screen, bounds: const Rect(row: 0, col: 0, width: 10, height: 4));
    r.attach();
    vt.feed(io.written.toString());
    io.written.clear();
    return r;
  }

  /// The visible grid text (the 4 region rows), top to bottom.
  List<String> _visibleRows() {
    return [for (var r = 0; r < 4; r++) vt.rowText(r).substring(0, 10)];
  }

  group('retention + scrollBy', () {
    test('overflowing content evicts older rows to history, not to oblivion', () {
      final chat = _region();
      for (var i = 0; i < 6; i++) {
        chat.write('L$i\n');
      }
      vt.feed(io.written.toString());
      io.written.clear();

      // The window holds the last few; older rows are retained in history
      // (the trailing newline after L5 scrolls once more, so 3 are retained).
      expect(chat.debugHistoryLength, 3);
      expect(_visibleRows().join('|'), contains('L5'));
      expect(_visibleRows().join('|'), isNot(contains('L0')));

      // Paging back (PgUp) reveals the retained older rows.
      chat.scrollBy(-4); // one page back (clamped to maxOffset = 2)
      vt.feed(io.written.toString());
      io.written.clear();
      expect(chat.debugScrollOffset, 2);
      expect(_visibleRows().join('|'), contains('L0'));
      expect(_visibleRows().join('|'), contains('L1'));
    });

    test('at the tail the offset is 0 and the newest row is on screen', () {
      final chat = _region();
      for (var i = 0; i < 6; i++) {
        chat.write('L$i\n');
      }
      vt.feed(io.written.toString());
      io.written.clear();
      expect(chat.isTailPinned, isTrue);
      expect(chat.debugScrollOffset, 0);
      // Bottom row of the window holds the newest line.
      expect(_visibleRows().last, contains('L5'));
    });
  });

  group('stay-put while new content streams', () {
    test('writing while scrolled up holds the view and bumps the counter', () {
      final chat = _region();
      for (var i = 0; i < 6; i++) {
        chat.write('L$i\n');
      }
      vt.feed(io.written.toString());
      io.written.clear();

      // Scroll back to the very top of the history (maxOffset = 2).
      chat.scrollBy(-4);
      vt.feed(io.written.toString());
      io.written.clear();
      final beforeTop = _visibleRows().first;
      expect(beforeTop, contains('L0'));
      expect(chat.newWhileScrolled, 0);

      // New content arrives while scrolled up. The view must stay put...
      chat.write('L6\n');
      vt.feed(io.written.toString());
      io.written.clear();
      expect(_visibleRows().first, contains('L0'));
      expect(_visibleRows().join('|'), isNot(contains('L6')),
          reason: 'the new line is below the visible window');
      // ...and the badge counter tracks it.
      expect(chat.newWhileScrolled, 1);
      expect(chat.isTailPinned, isFalse);
    });

    test('paging back to the tail clears the counter and shows the new lines', () {
      final chat = _region();
      for (var i = 0; i < 6; i++) {
        chat.write('L$i\n');
      }
      vt.feed(io.written.toString());
      io.written.clear();
      chat.scrollBy(-4);
      vt.feed(io.written.toString());
      io.written.clear();
      chat.write('L6\n');
      vt.feed(io.written.toString());
      io.written.clear();
      expect(chat.newWhileScrolled, 1);

      // PgDn back to the tail.
      chat.scrollBy(4);
      vt.feed(io.written.toString());
      io.written.clear();
      expect(chat.isTailPinned, isTrue);
      expect(chat.newWhileScrolled, 0);
      expect(_visibleRows().last, contains('L6'));
    });
  });

  group('clear resets to the tail', () {
    test('resetAfterClear drops history and the offset', () {
      final chat = _region();
      for (var i = 0; i < 6; i++) {
        chat.write('L$i\n');
      }
      vt.feed(io.written.toString());
      io.written.clear();
      chat.scrollBy(-4);
      vt.feed(io.written.toString());
      io.written.clear();
      expect(chat.debugHistoryLength, 3);
      expect(chat.debugScrollOffset, 2);

      chat.resetAfterClear();
      chat.scrollToTail();
      expect(chat.debugHistoryLength, 0);
      expect(chat.isTailPinned, isTrue);
    });
  });

  group('PanelFrame badge + key claim', () {
    PanelFrame _frame() {
      final frame = PanelFrame(
        screen: screen,
        label: 'p',
        conversationId: 'c1',
      )..setReservesInput(false);
      frame.setOuter(const Rect(row: 0, col: 0, width: 20, height: 6));
      vt.feed(io.written.toString());
      io.written.clear();
      return frame;
    }

    test('setScrollBadge renders "↓ N new" right-aligned on the bottom rail', () {
      final frame = _frame();
      frame.setScrollBadge(3);
      vt.feed(io.written.toString());
      io.written.clear();
      // The bottom border row (row 5) carries the badge.
      expect(vt.rowText(5), contains('↓ 3 new'));
    });

    test('setScrollBadge(0) clears the badge', () {
      final frame = _frame();
      frame.setScrollBadge(3);
      vt.feed(io.written.toString());
      io.written.clear();
      frame.setScrollBadge(0);
      vt.feed(io.written.toString());
      io.written.clear();
      expect(vt.rowText(5), isNot(contains('new')));
    });

    test('handleEvent claims PgUp/PgDn via onScroll and returns true', () {
      final frame = _frame();
      int? captured;
      frame.onScroll = (delta) => captured = delta;

      expect(frame.handleEvent(ArrowKey(ArrowDirection.pageUp)), isTrue);
      expect(captured, -1);
      expect(frame.handleEvent(ArrowKey(ArrowDirection.pageDown)), isTrue);
      expect(captured, 1);
    });

    test('without onScroll, PgUp/PgDn fall through (returns false)', () {
      final frame = _frame(); // no onScroll set
      expect(frame.handleEvent(ArrowKey(ArrowDirection.pageUp)), isFalse);
      expect(frame.handleEvent(ArrowKey(ArrowDirection.pageDown)), isFalse);
      // A plain char still falls through too.
      expect(frame.handleEvent(CharInput('a')), isFalse);
    });

    test('regular arrows are not claimed even with onScroll set', () {
      final frame = _frame();
      frame.onScroll = (delta) => fail('onScroll must not fire for regular arrows');
      expect(frame.handleEvent(ArrowKey(ArrowDirection.up)), isFalse);
      expect(frame.handleEvent(ArrowKey(ArrowDirection.left)), isFalse);
    });
  });
}
