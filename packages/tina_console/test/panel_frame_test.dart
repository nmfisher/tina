import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

/// Chrome-only tests for [PanelFrame]. The frame is content-agnostic, so these
/// construct a frame with NO chat and assert only border / focus / busy-comet /
/// input-rect behavior. Chat-coupled behavior (input-row reservation,
/// history-preservation) lives in `chat_region_panel_content_test.dart`.
void main() {
  // A split layout gives a right-hand info column the secondary panel lives in.
  // We place the panel explicitly via setOuter, so the exact layout rect doesn't
  // matter — only that the screen has a frame and ansi is on.
  late FakeStdio io;
  late Screen screen;
  late VirtualTerminal vt;

  setUp(() {
    io = FakeStdio()..columns = 100;
    // Split with no info frame — the real spawn layout. Panels self-draw their
    // own borders inside the (frameless) info column.
    final layout = ScreenLayout.fromSize(100, 24, split: true, drawInfoFrame: false);
    screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
    vt = VirtualTerminal(width: 100, height: 24);
    screen.redrawFrame();
    vt.feed(io.written.toString());
    io.written.clear();
  });

  // A panel sized to sit entirely inside the info column (well clear of the
  // chat box's right border), the way the coordinator lays them out.
  const panelRect = Rect(row: 5, col: 68, width: 28, height: 6);
  // panelRect interior: rows 6..9, cols 69..94.

  group('PanelFrame (secondary chrome)', () {
    test('setOuter draws a bordered box with the label in the title', () {
      final panel = PanelFrame(
        screen: screen,
        label: 'glm/glm-4.6',
        conversationId: 'c1',
      );
      panel.setOuter(panelRect);

      vt.feed(io.written.toString());
      // Top border corner + title at the panel's top-left.
      expect(vt.charAt(5, 68), '┌');
      expect(vt.rowText(5).substring(69, 80), startsWith('glm/glm-4.6'));
      // Bottom border corners.
      expect(vt.charAt(10, 68), '└');
      expect(vt.charAt(10, 95), '┘');
      // Side borders on an interior row.
      expect(vt.charAt(7, 68), '│');
      expect(vt.charAt(7, 95), '│');
    });

    test('focus fires onFocus and tints the border cyan', () {
      var focused = 0;
      final panel = PanelFrame(
        screen: screen,
        label: 'm',
        conversationId: 'c1',
      )..onFocus = () => focused++;
      panel.setOuter(panelRect);
      io.written.clear();

      panel.focus();
      expect(focused, 1);
      // The focus accent (cyan, theme.border.focus = '36') wraps the border.
      expect(io.written.toString(), contains('\x1b[36m'));
    });

    test('unhighlight repaints even when the panel is not focused (cycling)',
        () {
      // Regression: while cycling, the panel losing the yellow highlight is
      // usually *not* focused. unhighlight must still repaint, else its border
      // stays yellow on screen and multiple panels read as highlighted at once.
      final panel = PanelFrame(
        screen: screen,
        label: 'm',
        conversationId: 'c1',
      );
      panel.setOuter(panelRect);
      io.written.clear();

      panel.highlight(); // turns yellow
      io.written.clear();
      expect(panel.hasFocus, isFalse); // not focused — just highlighted

      panel.unhighlight();
      // A repaint happened: the border was rewritten (no longer yellow).
      final out = io.written.toString();
      expect(out, isNot(isEmpty));
      expect(out, isNot(contains('\x1b[33m')), reason: 'yellow highlight cleared');
    });

    test('setBusy repaints the border (busy cue) without firing onFocus', () {
      var focused = 0;
      final panel = PanelFrame(
        screen: screen,
        label: 'm',
        conversationId: 'c1',
      )..onFocus = () => focused++;
      addTearDown(panel.dispose);
      panel.setOuter(panelRect);
      io.written.clear();

      panel.setBusy(true);
      expect(focused, 0);
      // Busy comet cells use their own independent colors; the border frame
      // is plain (no accent) when unfocused.
      expect(io.written.toString(), isNot(contains('\x1b[36m')));
      // Idempotent: a second true doesn't repaint.
      io.written.clear();
      panel.setBusy(true);
      expect(io.written.toString(), isEmpty);
    });

    test('busy uses focus accent when panel has focus', () {
      final panel = PanelFrame(
        screen: screen,
        label: 'm',
        conversationId: 'c1',
      );
      addTearDown(panel.dispose);
      panel.setOuter(panelRect);
      panel.focus();
      io.written.clear();

      panel.setBusy(true);
      // Focused + busy → cyan accent.
      expect(io.written.toString(), contains('\x1b[36m'));
    });

    test('handleEvent falls through to the editor (Option 1)', () {
      final panel = PanelFrame(
        screen: screen,
        label: 'm',
        conversationId: 'c1',
      );
      for (final e in [
        CharInput('a'),
        ControlKey(ControlCode.enter),
        ArrowKey(ArrowDirection.up),
      ]) {
        expect(panel.handleEvent(e), isFalse,
            reason: 'panels show scrollback only; input is shared');
      }
    });

    test('inputRect is the bottom interior row', () {
      final panel = PanelFrame(
        screen: screen,
        label: 'm',
        conversationId: 'c1',
      );
      panel.setOuter(panelRect); // rows 5..10, cols 68..95; interior 6..9
      final ir = panel.inputRect;
      expect(ir.row, 9);
      expect(ir.col, 69);
      expect(ir.width, 26);
      expect(ir.height, 1);
    });

    test('inputRect is empty for a panel too short to host input', () {
      final panel = PanelFrame(
        screen: screen,
        label: 'm',
        conversationId: 'c1',
      );
      panel.setOuter(const Rect(row: 5, col: 68, width: 28, height: 2));
      expect(panel.inputRect.isEmpty, isTrue);
    });
  });

  group('PanelFrame (primary chrome)', () {
    // The primary panel wraps screen.chat and — like a secondary — draws its own
    // titled border. There is no separate Screen-owned chat frame anymore.
    const primaryRect = Rect(row: 0, col: 0, width: 60, height: 24);

    test('renders a titled border using the label', () {
      final panel = PanelFrame(
        screen: screen,
        label: 'glm/glm-4.6',
        conversationId: 'primary',
      );
      panel.setOuter(primaryRect);
      vt.feed(io.written.toString());

      expect(vt.charAt(0, 0), '┌');
      expect(vt.rowText(0), contains('glm/glm-4.6'));
      expect(vt.charAt(23, 0), '└');
      expect(vt.charAt(23, 59), '┘');
      // Side borders on an interior row.
      expect(vt.charAt(5, 0), '│');
      expect(vt.charAt(5, 59), '│');
    });

    test('focus tints the border cyan and fires onFocus', () {
      var focused = 0;
      final panel = PanelFrame(
        screen: screen,
        label: 'main',
        conversationId: 'primary',
      )..onFocus = () => focused++;
      panel.setOuter(primaryRect);
      io.written.clear();

      panel.focus();
      expect(focused, 1);
      // The focus accent (cyan) is painted by the panel itself now.
      expect(io.written.toString(), contains('\x1b[36m'));
    });

    test('bounds is the outer rect after setOuter (empty before)', () {
      final panel = PanelFrame(
        screen: screen,
        label: 'main',
        conversationId: 'primary',
      );
      expect(panel.bounds.isEmpty, isTrue); // no outer assigned yet
      panel.setOuter(primaryRect);
      expect(panel.bounds, primaryRect);
    });

    test('interior is the border-exclusive content rect', () {
      final panel = PanelFrame(
        screen: screen,
        label: 'main',
        conversationId: 'primary',
      );
      panel.setOuter(primaryRect);
      // primaryRect rows 0..23, cols 0..59 → interior rows 1..22, cols 1..58.
      // (Rect has no operator ==, so compare fields.)
      expect(panel.interior.row, 1);
      expect(panel.interior.col, 1);
      expect(panel.interior.width, 58);
      expect(panel.interior.height, 22);
    });
  });

  group('PanelFrame busy comet', () {
    int? headCol(VirtualTerminal v, int row) {
      for (var c = 0; c < v.width; c++) {
        if (v.charAt(row, c) == '━') return c;
      }
      return null;
    }

    test('setBusy(true) sweeps a comet head along the top and bottom rails', () {
      final panel = PanelFrame(
        screen: screen,
        label: 'm',
        conversationId: 'c1',
      );
      addTearDown(panel.dispose);
      panel.setOuter(panelRect);
      io.written.clear();

      panel.setBusy(true);
      vt.feed(io.written.toString());
      expect(headCol(vt, 5), isNotNull, reason: 'head on the top rail');
      expect(headCol(vt, 10), isNotNull, reason: 'head on the bottom rail');
      // Corners stay solid.
      expect(vt.charAt(5, 68), '┌');
      expect(vt.charAt(5, 95), '┐');
    });

    test('the busy rail is cyan and the head is bold truecolor', () {
      final panel = PanelFrame(
        screen: screen,
        label: 'm',
        conversationId: 'c1',
      );
      addTearDown(panel.dispose);
      panel.setOuter(panelRect);
      io.written.clear();

      panel.setBusy(true);
      final out = io.written.toString();
      expect(out, contains('38;2;30;110;130'), reason: 'cyan rail');
      expect(out, contains('1;38;2;'), reason: 'bold truecolor comet head');
    });

    test('advancing the tick moves the head one cell to the right', () {
      final panel = PanelFrame(
        screen: screen,
        label: 'm',
        conversationId: 'c1',
      );
      addTearDown(panel.dispose);
      panel.setOuter(panelRect);

      panel.setBusy(true);
      vt.feed(io.written.toString());
      final at0 = headCol(vt, 10)!; // bottom rail (no title shift)

      panel.advanceBusyTick(); // tick 0 -> 1
      vt.feed(io.written.toString());
      final at1 = headCol(vt, 10)!;

      expect(at1, at0 + 1);
    });

    test('setBusy(false) stops the comet', () {
      final panel = PanelFrame(
        screen: screen,
        label: 'm',
        conversationId: 'c1',
      );
      addTearDown(panel.dispose);
      panel.setOuter(panelRect);

      panel.setBusy(true);
      io.written.clear();
      panel.setBusy(false);
      vt.feed(io.written.toString());
      expect(headCol(vt, 5), isNull, reason: 'no head after clear');
      expect(headCol(vt, 10), isNull);
    });
  });
}
