import 'package:tina/tui/spend_pause_dialog.dart';
import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import '../helpers/overlay_fixtures.dart';

void main() {
  test('Enter returns true (continue)', () async {
    final screen = fakeScreen();
    final result = await runSpendPauseDialog(
      screen: screen,
      editor: LineEditor(screen: screen),
      readEvent: () async => ControlKey(ControlCode.enter),
    );
    expect(result, isTrue);
  });

  test('Esc returns false (abort)', () async {
    final screen = fakeScreen();
    final result = await runSpendPauseDialog(
      screen: screen,
      editor: LineEditor(screen: screen),
      readEvent: () async => EscapeKey(),
    );
    expect(result, isFalse);
  });

  test('ignores other keys until Enter/Esc', () async {
    final screen = fakeScreen();
    final events = <InputEvent>[
      CharInput('x'),
      ArrowKey(ArrowDirection.up),
      ControlKey(ControlCode.enter),
    ];
    var i = 0;
    final result = await runSpendPauseDialog(
      screen: screen,
      editor: LineEditor(screen: screen),
      readEvent: () async => events[i++],
    );
    expect(result, isTrue);
    expect(i, 3, reason: 'the first two keys are ignored');
  });
}
