import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

void main() {
  group('ConfirmDialog', () {
    late FakeStdio io;
    late Screen screen;
    late VirtualTerminal vt;
    late ScreenLayout layout;
    late ConfirmDialog dialog;

    setUp(() {
      io = FakeStdio();
      layout = ScreenLayout.fromSize(120, 30);
      screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
      vt = VirtualTerminal(width: 120, height: 30);
      screen.redrawFrame();
      vt.feed(io.written.toString());
      io.written.clear();
      dialog = ConfirmDialog(screen);
    });

    test('first trigger returns false and shows the box', () {
      final confirmed = dialog.trigger();
      vt.feed(io.written.toString());
      expect(confirmed, isFalse);
      expect(dialog.isVisible, isTrue);
      // Look for the dialog text on screen.
      var found = false;
      for (var r = 0; r < layout.height; r++) {
        if (vt.rowText(r).contains('Ctrl+C again to exit')) {
          found = true;
          break;
        }
      }
      expect(found, isTrue);
    });

    test('second trigger returns true (host should exit)', () {
      dialog.trigger();
      expect(dialog.trigger(), isTrue);
    });

    test('dismiss hides the dialog and restores borders', () {
      dialog.trigger();
      io.written.clear();
      dialog.dismiss();
      vt.feed(io.written.toString());
      expect(dialog.isVisible, isFalse);
      // Confirm no message text remains.
      var leftover = false;
      for (var r = 0; r < layout.height; r++) {
        if (vt.rowText(r).contains('Ctrl+C again to exit')) leftover = true;
      }
      expect(leftover, isFalse);
      // Info-box frame intact.
      vt.assertBorders(5, layout.infoLeftCol, layout.infoRightCol,
          layout.infoRightCol);
    });

    test('reset clears trigger and hides', () {
      dialog.trigger();
      dialog.reset();
      expect(dialog.isVisible, isFalse);
    });
  });
}
