import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

void main() {
  group('Spinner', () {
    test('disabled spinner writes nothing', () async {
      final io = FakeStdio();
      final screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(120, 30),
        ansi: AnsiCapable.yes,
      );
      screen.redrawFrame();
      io.written.clear();
      final s = Spinner(enabled: false, region: screen.status);
      s.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      s.stop();
      expect(io.written.toString(), isEmpty);
    });

    test('a live spinner writes nothing (animation retired)', () async {
      final io = FakeStdio();
      final layout = ScreenLayout.fromSize(120, 30);
      final screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
      final vt = VirtualTerminal(width: 120, height: 30);
      screen.redrawFrame();
      vt.feed(io.written.toString());
      io.written.clear();

      // The info panel is now a static reference surface — the spinner no
      // longer draws a thinking indicator or an idle beach scene. start/stop/
      // startIdle across a timer tick must produce no output and leave the
      // info box's borders untouched.
      final s = Spinner(enabled: true, region: screen.status, rowOffset: 2);
      s.start(label: 'thinking');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      s.stop();
      s.startIdle();
      s.dispose();

      expect(io.written.toString(), isEmpty);
      final row = vt.rowText(layout.status.row + 2);
      expect(row[layout.infoLeftCol], '│');
      expect(row[layout.infoRightCol], '│');
    });

    test('spinner without a region is a no-op', () {
      final s = Spinner(enabled: true);
      s.start();
      s.stop();
    });
  });

  group('ProgressCounter', () {
    test('start/tick/finish writes and clears row', () {
      final io = FakeStdio();
      final layout = ScreenLayout.fromSize(120, 30);
      final screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
      final vt = VirtualTerminal(width: 120, height: 30);
      screen.redrawFrame();
      vt.feed(io.written.toString());
      io.written.clear();

      final p = ProgressCounter(
        enabled: true,
        region: screen.status,
        rowOffset: 3,
      );
      p.start('files', total: 10);
      vt.feed(io.written.toString());
      io.written.clear();
      expect(vt.rowText(layout.status.row + 3).contains('files'), isTrue);

      p.tick(5);
      vt.feed(io.written.toString());
      io.written.clear();
      expect(vt.rowText(layout.status.row + 3).contains('5/10'), isTrue);

      p.finish();
      vt.feed(io.written.toString());
      final right = vt
          .rowText(layout.status.row + 3)
          .substring(layout.status.col, layout.rightBorderCol);
      expect(right.trim(), isEmpty);
    });

    test('finish with message replaces row instead of clearing', () {
      final io = FakeStdio();
      final layout = ScreenLayout.fromSize(120, 30);
      final screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
      final vt = VirtualTerminal(width: 120, height: 30);
      screen.redrawFrame();
      vt.feed(io.written.toString());

      final p = ProgressCounter(
        enabled: true,
        region: screen.status,
        rowOffset: 1,
      );
      p.start('idx');
      p.tick(7);
      p.finish(message: 'done');
      vt.feed(io.written.toString());
      expect(vt.rowText(layout.status.row + 1).contains('done'), isTrue);
    });
  });
}
