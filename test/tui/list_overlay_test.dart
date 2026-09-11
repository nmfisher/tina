import 'package:test/test.dart';
import 'package:tina/tui/spawn_overlay.dart';
import 'package:tina_console/tina_console.dart';

import '../helpers/overlay_fixtures.dart';
import '../helpers/fake_stdio.dart';

void main() {
  for (final size in [
    (1, 6),
    (4, 8),
    (20, 10),
    (40, 12),
    (80, 15),
    (80, 16),
    (80, 24),
  ]) {
    for (final body in [
      null,
      List.filled(20, 'An explanation that wraps.').join('\n'),
    ]) {
      test(
        'list picker selects and cancels at $size, body=${body != null}',
        () async {
          for (final cancel in [false, true]) {
            final screen = fakeScreen(columns: size.$1, lines: size.$2);
            final events = CannedEvents()
              ..events = [
                for (var i = 0; i < 9; i++) ArrowKey(ArrowDirection.down),
                if (cancel)
                  ControlKey(ControlCode.ctrlC)
                else
                  ControlKey(ControlCode.enter),
              ];
            final result = await runListOverlay<int>(
              screen: screen,
              editor: LineEditor(screen: screen),
              entries: [
                for (var i = 0; i < 10; i++) (display: 'Option $i', value: i),
              ],
              title: 'Select',
              footer: 'enter select / esc cancel',
              body: body,
              readEvent: events.readEvent,
            ).timeout(overlayTimeout);
            expect(result, cancel ? isNull : 9);
          }
        },
      );
    }
  }

  test(
    'short body picker paints the selected option after scrolling and resize',
    () async {
      final io = FakeStdio();
        final screen = Screen(io: io, layout: ScreenLayout.fromSize(80, 24));
      var reads = 0;
      final result = await runListOverlay<int>(
        screen: screen,
        editor: LineEditor(screen: screen),
        entries: [
          for (var i = 0; i < 10; i++) (display: 'Option $i', value: i),
        ],
        title: 'Select',
        footer: 'esc cancel',
        body: List.filled(20, 'Explanation').join('\n'),
        readEvent: () async {
          if (reads == 0) screen.resize(ScreenLayout.fromSize(40, 10));
          if (reads++ < 9) {
            io.written.clear();
            return ArrowKey(ArrowDirection.down);
          }
          final painted = io.written.toString().replaceAll(
            RegExp(r'\x1b\[[0-9;?]*[ -/]*[@-~]'),
            '',
          );
          expect(painted, contains('▸ Option 9'));
          expect(painted, contains('└'));
          return ControlKey(ControlCode.enter);
        },
      ).timeout(overlayTimeout);
      expect(result, 9);
    },
  );

  for (final body in [null, 'Explanation']) {
    test(
      'empty list cancels at minimum height, body=${body != null}',
      () async {
        final screen = fakeScreen(columns: 20, lines: 6);
        expect(
          await runListOverlay<int>(
            screen: screen,
            editor: LineEditor(screen: screen),
            entries: [],
            title: 'Empty',
            footer: 'esc cancel',
            body: body,
            readEvent: () async => EscapeKey(),
          ),
          isNull,
        );
      },
    );
  }
}
