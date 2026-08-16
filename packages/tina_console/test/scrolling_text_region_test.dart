import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

void main() {
  group('ScrollingTextRegion (split)', () {
    late FakeStdio io;
    late Screen screen;
    late VirtualTerminal vt;
    late ScreenLayout layout;

    setUp(() {
      io = FakeStdio();
      layout = ScreenLayout.fromSize(100, 24);
      screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
      vt = VirtualTerminal(width: 100, height: 24);
      screen.redrawFrame();
      vt.feed(io.written.toString());
      io.written.clear();
    });

    test('writes plain text into chat bounds', () {
      screen.chat.write('hello world');
      vt.feed(io.written.toString());
      // Bottom-aligned: first content lands on the last row of the region.
      final bottomRow = layout.chat.row + layout.chat.height - 1;
      final row = vt.rowText(bottomRow);
      expect(row.substring(layout.chat.col, layout.chat.col + 11), 'hello world');
    });

    test('newline advances to the next row', () {
      screen.chat.write('a\nb');
      vt.feed(io.written.toString());
      // Bottom-aligned: two rows of content sit at the bottom of the region.
      final aRow = layout.chat.row + layout.chat.height - 2;
      final bRow = layout.chat.row + layout.chat.height - 1;
      expect(vt.charAt(aRow, layout.chat.col), 'a');
      expect(vt.charAt(bRow, layout.chat.col), 'b');
    });

    test('long text wraps at chat width', () {
      final s = 'x' * (layout.chat.width + 5);
      screen.chat.write(s);
      vt.feed(io.written.toString());
      // Bottom-aligned: two wrapped rows sit at the bottom of the region.
      final row0Screen = layout.chat.row + layout.chat.height - 2;
      final row1Screen = layout.chat.row + layout.chat.height - 1;
      // First row full of x.
      final row0 = vt.rowText(row0Screen);
      expect(row0.substring(layout.chat.col, layout.chat.col + layout.chat.width),
          'x' * layout.chat.width);
      // Five x's on the next row.
      final row1 = vt.rowText(row1Screen);
      expect(row1.substring(layout.chat.col, layout.chat.col + 5), 'x' * 5);
      // Right panel must be empty on both rows.
      for (final r in [row0Screen, row1Screen]) {
        final right =
            vt.rowText(r).substring(layout.infoLeftCol + 1, layout.infoRightCol);
        expect(right.trim(), isEmpty);
      }
    });

    test('text never crosses the divider', () {
      // Write way more than width to ensure clipping is doing its job.
      screen.chat.write('z' * 5000);
      vt.feed(io.written.toString());
      for (var r = layout.chat.row; r < layout.chat.row + layout.chat.height; r++) {
        final right = vt.rowText(r).substring(layout.infoLeftCol + 1, layout.infoRightCol);
        expect(right.trim(), isEmpty,
            reason: 'row $r: text leaked into right panel');
      }
    });

    test('scrolls when content exceeds bounds', () {
      // Fill region height + extra rows.
      final extra = 3;
      for (var i = 0; i < layout.chat.height + extra; i++) {
        screen.chat.write('line $i\n');
      }
      vt.feed(io.written.toString());

      // The bottom row of the chat region should hold the last completed
      // line, which is one before the cursor's blank current row.
      final lastLineRow = layout.chat.row + layout.chat.height - 1;
      // After scrolling, the row before "current empty" holds 'line {n-1}'
      final lastLineNum = layout.chat.height + extra - 1;
      final expectedText = 'line $lastLineNum';
      // Walk the chat region rows; expect the most recent finished line to
      // appear somewhere in the visible window.
      final found = <String>[];
      for (var r = layout.chat.row;
          r < layout.chat.row + layout.chat.height;
          r++) {
        final t = vt.rowText(r).substring(layout.chat.col, layout.dividerCol).trim();
        if (t.isNotEmpty) found.add(t);
      }
      expect(found, contains(expectedText));
      // First few lines must have scrolled out.
      expect(found, isNot(contains('line 0')));
    });

    test('shrink mid-stream keeps the most recent content (tin-4k8w)', () {
      // Regression for the mid-stream resize wipe: with a partially-filled
      // buffer (content top-aligned, blanks at the bottom), shrinking the
      // terminal used to keep the BLANK tail and evict every content row
      // into scrollback — the chat went blank after a resize mid-turn. The
      // window must keep the most recent content instead.
      final n = 6; // fewer than the region height — buffer is NOT full
      for (var i = 0; i < n; i++) {
        screen.chat.write('streamed line $i\n');
      }
      vt.feed(io.written.toString());
      io.written.clear();

      // Shrink the terminal mid-turn: 100x24 -> 100x12.
      final small = ScreenLayout.fromSize(100, 12);
      screen.resize(small);
      vt.feed(io.written.toString());

      final seen = <String>[];
      for (var r = small.chat.row;
          r < small.chat.row + small.chat.height;
          r++) {
        final t = vt.rowText(r).substring(small.chat.col, small.chat.col + small.chat.width).trim();
        if (t.isNotEmpty) seen.add(t);
      }
      // The most recent streamed lines survive the shrink.
      expect(seen, contains('streamed line 5'));
      expect(seen, contains('streamed line 4'));
      // Content is bottom-aligned: the tail sits on the last region row.
      final lastRow =
          small.chat.row + small.chat.height - 1;
      expect(
        vt.rowText(lastRow).substring(small.chat.col, small.chat.col + 15),
        'streamed line 5',
      );
    });

    test('shrink mid-stream with a full buffer never merges two rows (tin-m2vq)', () {
      // Regression for the resize-storm merge: once the buffer is FULL (the
      // streaming steady state — lines have been scrolling), a height shrink
      // left the write cursor pointing at a row that already held content, so
      // the next streamed line appended to it and the two rendered as one row
      // ("streamed line 29streamed line 30"), persistently.
      final full = layout.chat.height + 10; // buffer full + scrolling
      for (var i = 0; i < full; i++) {
        screen.chat.write('streamed line $i\n');
      }
      vt.feed(io.written.toString());
      io.written.clear();

      // Shrink the terminal mid-turn: 100x24 -> 100x12.
      final small = ScreenLayout.fromSize(100, 12);
      screen.resize(small);
      vt.feed(io.written.toString());
      io.written.clear();

      // The stream continues after the shrink.
      for (var i = full; i < full + 6; i++) {
        screen.chat.write('streamed line $i\n');
      }
      vt.feed(io.written.toString());

      final seen = <String>[];
      for (var r = small.chat.row;
          r < small.chat.row + small.chat.height;
          r++) {
        final t = vt
            .rowText(r)
            .substring(small.chat.col, small.chat.col + small.chat.width)
            .trim();
        if (t.isNotEmpty) seen.add(t);
      }
      // No row may carry text from two streamed lines.
      for (final t in seen) {
        final merges = RegExp(r'streamed line \d+streamed line \d+').allMatches(t);
        expect(merges, isEmpty,
            reason: 'two streamed lines rendered on one row: "$t"');
      }
      // And the newest lines are all present somewhere.
      expect(seen.join('\n'), contains('streamed line ${full + 5}'));
    });

    test('colorize methods pass ANSI through without affecting width', () {
      screen.chat.dim('hi');
      vt.feed(io.written.toString());
      // Bottom-aligned: content on the last row.
      final bottomRow = layout.chat.row + layout.chat.height - 1;
      final row = vt.rowText(bottomRow);
      expect(row.substring(layout.chat.col, layout.chat.col + 2), 'hi');
    });

    test('setBottomInset is non-destructive (no buffered row lost)', () {
      // Fill a few rows, then toggle the bottom inset on and off.
      // Toggling an inset only shifts content visually (it reserves a
      // bottom row); it must never drop a buffered row, unlike
      // [setBounds] which reconciles the buffer height.
      final n = 3;
      for (var i = 0; i < n; i++) screen.chat.write('row $i\n');
      vt.feed(io.written.toString());
      io.written.clear();

      Set<String> visibleContent() {
        final seen = <String>{};
        for (var r = layout.chat.row;
            r < layout.chat.row + layout.chat.height;
            r++) {
          final t = vt.rowText(r)
              .substring(layout.chat.col, layout.dividerCol)
              .trim();
          if (t.isNotEmpty) seen.add(t);
        }
        return seen;
      }

      final before = visibleContent();
      expect(before, hasLength(n));

      screen.chat.setBottomInset(1); // reserve the input row
      screen.chat.setBottomInset(0); // release it
      vt.feed(io.written.toString());

      final after = visibleContent();
      // Same rows are still present afterwards — none were dropped.
      expect(after, hasLength(n));
      expect(after.containsAll(before), isTrue);
    });
  });

  group('styled-row mechanism (primitives)', () {
    late FakeStdio io;
    late Screen screen;
    late VirtualTerminal vt;
    late ScreenLayout layout;

    setUp(() {
      io = FakeStdio();
      layout = ScreenLayout.fromSize(100, 24);
      screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
      vt = VirtualTerminal(width: 100, height: 24);
      screen.redrawFrame();
      vt.feed(io.written.toString());
      io.written.clear();
    });

    String chatRowText(int relRow) => vt
        .rowText(layout.chat.row + relRow)
        .substring(layout.chat.col, layout.chat.col + layout.chat.width);

    test('writeStyledLine renders a full-width reverse-video bar', () {
      screen.chat.writeStyledLine('> hi', '7');
      vt.feed(io.written.toString());

      final barRelRow = layout.chat.height - 1;
      expect(io.written.toString(), contains('\x1b[7m'));
      expect(chatRowText(barRelRow).substring(0, 4), '> hi');
      expect(chatRowText(barRelRow).substring(4).trim(), isEmpty);
      expect(chatRowText(barRelRow).length, layout.chat.width);
    });

    test('writeStyledLine bar survives a leaked reset from a prior colorized line',
        () {
      // dim('banner\n') wraps as \x1b[2mbanner\n\x1b[0m: the closing reset
      // lands on the NEXT row (after the newline). The user message then
      // appends to that polluted row. Its bar SGR must apply directly to the
      // text — not be cancelled by the leaked reset (_stripLeadingCsi).
      screen.chat.dim('banner\n');
      io.written.clear();
      screen.chat.writeStyledLine('hello', '7');
      final out = io.written.toString();
      expect(out, contains('\x1b[7mhello'),
          reason: 'the bar SGR must reach the text');
      expect(out, isNot(contains('\x1b[7m\x1b[0m')),
          reason: 'no bare reset between the bar SGR and the text');
    });

    test('beginStyle+appendStyled renders default-fg text with no background bar',
        () {
      screen.chat.beginStyle('39');
      screen.chat.appendStyled('hello\n');
      vt.feed(io.written.toString());

      final out = io.written.toString();
      expect(out, contains('\x1b[39mhello\x1b[0m'));
      expect(out, isNot(contains('\x1b[30;47m')));
      final contentRow = layout.chat.height - 1;
      expect(chatRowText(contentRow).substring(0, 5), 'hello');
      expect(chatRowText(contentRow).substring(5).trim(), isEmpty);
    });

    test('streamed beginStyle chunks form one continuous default-fg run', () {
      // Two separate chunks land on the same row; the style is applied once at
      // emit time, so there's a single default-foreground text run (not a
      // reset between chunks) and no padded background bar.
      screen.chat.beginStyle('39');
      screen.chat.appendStyled('foo ');
      screen.chat.appendStyled('bar\n');
      vt.feed(io.written.toString());

      final out = io.written.toString();
      expect(out, contains('\x1b[39mfoo bar\x1b[0m'));
      expect(out, isNot(contains('bar \x1b[0m')));
      final contentRow = layout.chat.height - 1;
      expect(chatRowText(contentRow).substring(0, 7), 'foo bar');
      expect(chatRowText(contentRow).substring(7).trim(), isEmpty);
    });

    test('a wrapped beginStyle message colors every wrapped row default-fg', () {
      final long = 'x' * (layout.chat.width + 5);
      screen.chat.beginStyle('39');
      screen.chat.appendStyled('$long\n');
      vt.feed(io.written.toString());

      final out = io.written.toString();
      expect(out, isNot(contains('\x1b[30;47m')));
      expect(out, contains('\x1b[39m'));
      final row0 = layout.chat.height - 2;
      final row1 = layout.chat.height - 1;
      expect(chatRowText(row0).substring(0, layout.chat.width), 'x' * layout.chat.width);
      expect(chatRowText(row1).substring(0, 5), 'x' * 5);
      expect(chatRowText(row1).substring(5).trim(), isEmpty);
    });

    test('a plain write after beginStyle prose ends the default-fg text', () {
      screen.chat.beginStyle('39');
      screen.chat.appendStyled('hello\n');
      vt.feed(io.written.toString());
      io.written.clear();

      screen.chat.dim('done\n');
      final dimOut = io.written.toString();
      expect(dimOut, contains('\x1b[2mdone'));
      expect(dimOut, isNot(contains('\x1b[39mdone')));
    });

    test('separator emits no rule in the TUI', () {
      screen.chat.separator();
      expect(io.written.toString(), isEmpty);
    });

    test('multi-turn: user bar stays distinct across beginStyle turns', () {
      // Realistic interleaving: a styled run ends with a newline, which leaves
      // _pendingStyle set and the cursor on a fresh tagged row. The next user
      // message (force-set by writeStyledLine) must still render as a USER bar
      // (reverse video), not inherit the default-fg style.
      //
      // The bottom-alignment redraw re-emits all rows on each write, so we
      // check which SGR wraps the specific text being written (not just any
      // SGR in the output).
      String styleOf(String text, void Function() write) {
        io.written.clear();
        write();
        final out = io.written.toString();
        if (out.contains('\x1b[7m$text')) return 'user';
        if (out.contains('\x1b[39m$text')) return 'agent';
        return 'none';
      }

      expect(styleOf('hello', () => screen.chat.writeStyledLine('hello', '7')),
          'user');
      expect(
          styleOf('Hi there!', () {
            screen.chat.beginStyle('39');
            screen.chat.appendStyled('Hi there!\n');
          }),
          'agent');
      expect(styleOf('bye', () => screen.chat.writeStyledLine('bye', '7')), 'user',
          reason: 'a user message after an agent turn must be a user bar');
      expect(
          styleOf('See you!', () {
            screen.chat.beginStyle('39');
            screen.chat.appendStyled('See you!\n');
          }),
          'agent');
    });

    test('beginStyle prose with no trailing newline, then a user message', () {
      // The trickier boundary: styled text ends mid-row (no \n), so the cursor
      // sits on a partial tagged row. The next user message must still land as
      // a user bar, not keep the prior style.
      screen.chat.writeStyledLine('q1', '7');
      screen.chat.beginStyle('39');
      screen.chat.appendStyled('partial answer'); // no trailing newline
      io.written.clear();

      screen.chat.writeStyledLine('q2', '7');
      expect(io.written.toString(), contains('\x1b[7m'));
    });
  });

  group('ScrollingTextRegion (passthrough)', () {
    test('writes directly to stdio', () {
      final io = FakeStdio();
      final screen = Screen.passthrough(io, ansi: AnsiCapable.yes);
      screen.chat.write('hello\n');
      expect(io.written.toString(), 'hello\n');
    });

    test('separator just emits newline', () {
      final io = FakeStdio();
      final screen = Screen.passthrough(io, ansi: AnsiCapable.yes);
      screen.chat.separator();
      expect(io.written.toString(), '\n');
    });

    test('colorize applies SGR when ansi enabled', () {
      final io = FakeStdio();
      final screen = Screen.passthrough(io, ansi: AnsiCapable.yes);
      screen.chat.red('boom');
      expect(io.written.toString(), '\x1b[31mboom\x1b[0m');
    });

    test('colorize is plain when ansi disabled', () {
      final io = FakeStdio();
      final screen = Screen.passthrough(io, ansi: AnsiCapable.no);
      screen.chat.red('boom');
      expect(io.written.toString(), 'boom');
    });
  });

  group('ScrollingTextRegion detach/attach', () {
    late FakeStdio io;
    late Screen screen;
    late VirtualTerminal vt;
    late ScreenLayout layout;

    setUp(() {
      io = FakeStdio();
      layout = ScreenLayout.fromSize(100, 24);
      screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
      vt = VirtualTerminal(width: 100, height: 24);
      screen.redrawFrame();
      vt.feed(io.written.toString());
      io.written.clear();
    });

    test('detach buffers writes instead of rendering', () {
      screen.chat.write('before');
      vt.feed(io.written.toString());
      io.written.clear();

      screen.chat.detach();
      expect(screen.chat.isDetached, isTrue);

      screen.chat.write('buffered');
      // Nothing written to the terminal while detached.
      expect(io.written.toString(), isEmpty);
    });

    test('attach re-renders rows and replays buffer', () {
      screen.chat.write('visible');
      vt.feed(io.written.toString());
      io.written.clear();

      screen.chat.detach();
      screen.chat.write('buffered\n');

      screen.chat.attach();
      vt.feed(io.written.toString());

      // Both the original row and the buffered content should be visible.
      var foundVisible = false;
      var foundBuffered = false;
      for (var r = layout.chat.row; r < layout.chat.row + layout.chat.height; r++) {
        final row = vt.rowText(r);
        if (row.contains('visible')) foundVisible = true;
        if (row.contains('buffered')) foundBuffered = true;
      }
      expect(foundVisible, isTrue);
      expect(foundBuffered, isTrue);
    });

    test('multiple detach/attach cycles accumulate correctly', () {
      screen.chat.detach();
      screen.chat.write('first\n');
      screen.chat.attach();
      vt.feed(io.written.toString());
      io.written.clear();

      screen.chat.detach();
      screen.chat.write('second\n');
      screen.chat.attach();
      vt.feed(io.written.toString());

      var foundFirst = false;
      var foundSecond = false;
      for (var r = layout.chat.row; r < layout.chat.row + layout.chat.height; r++) {
        final row = vt.rowText(r);
        if (row.contains('first')) foundFirst = true;
        if (row.contains('second')) foundSecond = true;
      }
      expect(foundFirst, isTrue);
      expect(foundSecond, isTrue);
    });

    test('resetAfterClear clears detached buffer', () {
      screen.chat.detach();
      screen.chat.write('buffered stuff');
      expect(screen.chat.isDetached, isTrue);

      screen.chat.resetAfterClear();
      // Re-attach and verify nothing replays.
      screen.chat.attach();
      vt.feed(io.written.toString());

      // Chat area should be empty (no 'buffered stuff').
      for (var r = layout.chat.row; r < layout.chat.row + layout.chat.height; r++) {
        final row = vt.rowText(r).substring(layout.chat.col, layout.dividerCol);
        expect(row.trim(), isEmpty);
      }
    });

    test('handleResize is no-op when detached', () {
      screen.chat.write('content');
      vt.feed(io.written.toString());
      io.written.clear();

      screen.chat.detach();

      // The ScrollingTextRegion itself should not write during resize.
      // screen.resize() will still redraw the frame — that's expected.
      // We just verify isDetached is maintained.
      final newLayout = ScreenLayout.fromSize(120, 24);
      screen.resize(newLayout);
      expect(screen.chat.isDetached, isTrue);
    });

    test('writing after grow-while-detached + attach does not overflow rows', () {
      // Fill past the chat height so the row buffer is full and the cursor
      // sits on the last row.
      for (var i = 0; i < layout.chat.height + 2; i++) {
        screen.chat.write('line $i\n');
      }
      vt.feed(io.written.toString());
      io.written.clear();

      screen.chat.detach();

      // Grow the terminal while detached. Without reconciling the row buffer
      // to the new (larger) height, the next writes after attach would index
      // past the end of _rows and throw.
      final bigger = ScreenLayout.fromSize(100, 48);
      screen.resize(bigger);
      screen.chat.attach();

      expect(() {
        for (var i = 0; i < 10; i++) {
          screen.chat.write('post $i\n');
        }
      }, returnsNormally);

      final bigVt = VirtualTerminal(width: 100, height: 48);
      bigVt.feed(io.written.toString());
      var found = false;
      for (var r = bigger.chat.row; r < bigger.chat.row + bigger.chat.height; r++) {
        if (bigVt.rowText(r).contains('post 9')) found = true;
      }
      expect(found, isTrue);
    });
  });

  group('ScrollingTextRegion (explicit bounds)', () {
    // A ScrollingTextRegion constructed with a bounds override renders into that rect
    // instead of screen.layout.chat — the foundation for spawned-conversation
    // column slots. The primary chat (no bounds) is covered by the group above.

    test('writes land inside the override rect, not layout.chat', () {
      final io = FakeStdio();
      final layout = ScreenLayout.fromSize(100, 24);
      final screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
      final vt = VirtualTerminal(width: 100, height: 24);
      screen.redrawFrame();
      vt.feed(io.written.toString());
      io.written.clear();

      const rect = Rect(row: 5, col: 60, width: 20, height: 4);
      final region = ScrollingTextRegion(screen, bounds: rect);
      region.write('hi');

      vt.feed(io.written.toString());
      // Bottom-aligned within the override rect: 'hi' on its last row.
      final bottomRow = rect.row + rect.height - 1;
      expect(vt.charAt(bottomRow, rect.col), 'h');
      expect(vt.charAt(bottomRow, rect.col + 1), 'i');
      // And nothing leaked into layout.chat (top-left of the screen).
      expect(vt.charAt(layout.chat.row, layout.chat.col), isNot('h'));
    });

    test('setBounds repositions the region and reconciles content', () {
      final io = FakeStdio();
      final layout = ScreenLayout.fromSize(100, 24);
      final screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
      final vt = VirtualTerminal(width: 100, height: 24);
      screen.redrawFrame();
      vt.feed(io.written.toString());
      io.written.clear();

      final region = ScrollingTextRegion(screen, bounds: const Rect(row: 2, col: 50, width: 10, height: 3));
      region.write('first\n');
      region.setBounds(const Rect(row: 10, col: 70, width: 12, height: 4));
      region.write('second');

      vt.feed(io.written.toString());
      // After the move, content bottom-aligns in the *new* rect.
      final bottomRow = 10 + 4 - 1;
      final row = vt.rowText(bottomRow);
      expect(row.substring(70, 76), 'second');
    });
  });
}
