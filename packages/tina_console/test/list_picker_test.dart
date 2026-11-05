import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';

class CannedEvents {
  List<InputEvent> events = [];
  void clear() => events = [];
  Future<InputEvent> readEvent() async {
    if (events.isEmpty) fail('picker requested an unexpected key');
    return events.removeAt(0);
  }
}

void main() {
  final canned = CannedEvents();

  setUp(canned.clear);

  (FakeStdio, Screen) rig() {
    final io = FakeStdio()..hasTerminalValue = false;
    final screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(80, 24, hasMenuBar: false),
    );
    return (io, screen);
  }

  Future<int?> run(Screen screen, {String? contextLine}) =>
      runListPickerOverlay(
        screen: screen,
        title: 'Rewind conversation',
        items: const [
          ListPickerItem('first message', detail: '1  10:00'),
          ListPickerItem('second message', detail: '2  10:01'),
          ListPickerItem('summarized earlier turns  [compaction]',
              detail: '3  10:02'),
        ],
        contextLine: contextLine,
        readEvent: canned.readEvent,
        footer: '↑↓ move · Enter rewind here · Esc cancel',
      );

  test('enter selects the focused row; the context line renders', () async {
    final (io, screen) = rig();
    canned.events = [
      ArrowKey(ArrowDirection.down),
      ControlKey(ControlCode.enter),
    ];
    expect(
        await run(screen,
            contextLine: 'Rewinding removes the chosen message and '
                'everything after it.'),
        1);
    final output = io.written.toString();
    expect(output, contains('Rewind conversation'));
    expect(output, contains('first message'));
    expect(output, contains('second message'));
    expect(output, contains('compaction'));
    expect(output, contains('Rewinding removes the chosen message'));
    screen.dispose();
  });

  test('escape cancels — nothing is selected', () async {
    final (io, screen) = rig();
    canned.events = [EscapeKey()];
    expect(await run(screen), isNull);
    screen.dispose();
  });

  test('arrows move and clamp; page down reaches the last row', () async {
    final (io, screen) = rig();
    canned.events = [
      ArrowKey(ArrowDirection.up),
      ArrowKey(ArrowDirection.pageDown),
      ControlKey(ControlCode.enter),
    ];
    expect(await run(screen), 2);
    screen.dispose();
  });
}
