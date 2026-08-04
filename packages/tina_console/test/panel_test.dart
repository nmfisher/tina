import 'package:test/test.dart';

import 'package:tina_console/tina_console.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

void main() {
  group('TextPanel rendering (ANSI backend)', () {
    late FakeStdio io;
    late Screen screen;
    late VirtualTerminal vt;

    setUp(() {
      io = FakeStdio();
      screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(80, 24),
        ansi: AnsiCapable.no, // clean text, no SGR noise
      );
      vt = VirtualTerminal(width: 80, height: 24);
    });

    test('mount + setContent paints frame and content at the panel origin', () {
      final panel = TextPanel(
        screen,
        const Rect(row: 5, col: 5, width: 24, height: 6),
        title: 'Files',
      )..mount();
      panel.setContent(['alpha', 'beta']);
      vt.feed(io.written.toString());

      expect(vt.charAt(5, 5), '┌', reason: 'top-left corner at origin');
      expect(vt.rowText(5).contains('Files'), isTrue, reason: 'title in border');
      expect(vt.rowText(6).contains('alpha'), isTrue);
      expect(vt.rowText(7).contains('beta'), isTrue);
      expect(vt.charAt(10, 5), '└', reason: 'bottom-left corner');
      panel.unmount();
    });

    test('content longer than the inner width is clipped', () {
      final panel = TextPanel(
        screen,
        const Rect(row: 0, col: 0, width: 10, height: 4),
      )..mount();
      panel.setContent(['0123456789ABCDEF']); // innerWidth = 6
      vt.feed(io.written.toString());
      // Only 6 chars of content fit between the side borders.
      expect(vt.rowText(1).substring(2, 8), '012345');
      expect(vt.charAt(1, 9), '│', reason: 'right border before overflow');
      panel.unmount();
    });

    test('hide erases the area; show restores retained content', () {
      final panel = TextPanel(
        screen,
        const Rect(row: 5, col: 5, width: 24, height: 6),
      )..mount();
      panel.setContent(['alpha', 'beta']);
      vt.feed(io.written.toString());
      io.written.clear();

      panel.hide();
      vt.feed(io.written.toString());
      for (var r = 5; r <= 10; r++) {
        expect(vt.rowText(r).substring(5, 29).trim(), isEmpty,
            reason: 'row $r blank after hide');
      }
      expect(panel.isVisible, isFalse);
      io.written.clear();

      panel.show();
      vt.feed(io.written.toString());
      expect(vt.rowText(6).contains('alpha'), isTrue, reason: 'content restored');
      expect(panel.isVisible, isTrue);
      panel.unmount();
    });

    test('resize changes geometry and re-renders', () {
      final panel = TextPanel(
        screen,
        const Rect(row: 5, col: 5, width: 24, height: 6),
      )..mount();
      panel.setContent(['keep']);
      panel.resize(16, 4);
      vt.feed(io.written.toString());
      expect(panel.bounds.width, 16);
      expect(panel.bounds.height, 4);
      // Inner height is now 2; "keep" on the first content row.
      expect(vt.rowText(6).contains('keep'), isTrue);
      panel.unmount();
    });
  });

  group('TextPanel focus styling', () {
    test('focus changes border color only; border weight stays thin', () {
      final io = FakeStdio();
      final screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(80, 24),
        ansi: AnsiCapable.yes,
      );
      final panel = TextPanel(
        screen,
        const Rect(row: 0, col: 0, width: 12, height: 4),
      )..mount();
      panel.setContent(['x']);
      final unfocused = io.written.toString();
      expect(unfocused, contains('┌'), reason: 'thin corner regardless of focus');
      expect(unfocused, contains('\x1b[2m'), reason: 'unfocused is dim');
      expect(unfocused, isNot(contains('┏')),
          reason: 'no heavy characters ever — the weight swap was removed');
      io.written.clear();

      panel.focus();
      final focused = io.written.toString();
      expect(focused, contains('┌'), reason: 'still thin after focus');
      expect(focused, isNot(contains('┏')),
          reason: 'focus must not switch to a heavy border');
      expect(focused, contains('\x1b[36m'), reason: 'focused is cyan');
      expect(panel.hasFocus, isTrue);
      panel.unmount();
    });
  });

  group('Panel focus ring', () {
    test('FocusManager cycles focus between two panels and routes events', () {
      final io = FakeStdio();
      final screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(80, 24),
        ansi: AnsiCapable.no,
      );
      final p1 = TextPanel(screen, const Rect(row: 0, col: 0, width: 10, height: 4))
        ..mount()
        ..setContent(['one']);
      final p2 = TextPanel(screen, const Rect(row: 0, col: 12, width: 10, height: 4))
        ..mount()
        ..setContent(['two']);

      // `home` establishes the initial focus (p1), exactly as the app sets
      // `focusManager.home = chat` (lib/tui_coordinator.dart). Without it
      // engage() is a no-op — nothing is focused to cycle from. (The older
      // engage-jumps-to-the-next-panel semantics were replaced by
      // engage-highlights-the-current-focus; see commits 2dda859 / 89c88d6.)
      final fm = FocusManager()
        ..register(p1)
        ..register(p2)
        ..home = p1;
      expect(p1.hasFocus, isTrue);
      expect(p2.hasFocus, isFalse);

      // Route the cycle through the real input path: Ctrl+G engages cycling on
      // the current focus (p1 turns yellow), Tab advances the highlight to the
      // next panel, Enter commits it to the focus.
      fm.handleEvent(ControlKey(ControlCode.ctrlG));
      expect(fm.isCycling, isTrue);
      expect(fm.highlighted, same(p1));

      fm.handleEvent(ControlKey(ControlCode.tab));
      expect(fm.highlighted, same(p2));

      fm.handleEvent(ControlKey(ControlCode.enter));
      expect(p2.hasFocus, isTrue);
      expect(p1.hasFocus, isFalse);

      p1.unmount();
      p2.unmount();
    });
  });
}
