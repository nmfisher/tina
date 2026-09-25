import 'package:test/test.dart';
import 'package:tina/tui/session_picker_overlay.dart';
import 'package:tina_console/tina_console.dart';

import '../helpers/overlay_fixtures.dart';
import '../helpers/fake_stdio.dart';

void main() {
  /// Live group: one active session; disk group: two saved sessions, one of
  /// which carries a description (the first substantive prompt).
  Future<SessionPickerEntry?> runPicker(
    List<InputEvent> events, {
    List<
      ({String id, String title, String description, int messageCount})
    >?
    disk,
  }) {
    final screen = fakeScreen(columns: 80, lines: 24);
    final canned = CannedEvents()..events = events;
    return runSessionPickerOverlay(
      screen: screen,
      editor: LineEditor(screen: screen),
      live: [
        (
          id: 'live-1',
          label: 'current chat',
          isActive: true,
          isRunning: false,
          unread: 0,
        ),
      ],
      disk:
          disk ??
          const [
            (
              id: 'disk-a',
              title: 'Parser refactor',
              description: 'split the tokenizer into passes',
              messageCount: 12,
            ),
            (
              id: 'disk-b',
              title: 'Release chores',
              description: '',
              messageCount: 3,
            ),
          ],
      readEvent: canned.readEvent,
    ).timeout(overlayTimeout);
  }

  test('disk entries render title, description and message count', () async {
    final io = FakeStdio();
    final screen = Screen(io: io, layout: ScreenLayout.fromSize(80, 24));
    final canned = CannedEvents()..events = [EscapeKey()];
    await runSessionPickerOverlay(
      screen: screen,
      editor: LineEditor(screen: screen),
      live: [
        (
          id: 'live-1',
          label: 'current chat',
          isActive: true,
          isRunning: false,
          unread: 0,
        ),
      ],
      disk: const [
        (
          id: 'disk-a',
          title: 'Parser refactor',
          description: 'split the tokenizer into passes',
          messageCount: 12,
        ),
      ],
      readEvent: canned.readEvent,
    ).timeout(overlayTimeout);
    final painted = io.written.toString().replaceAll(
      RegExp(r'\x1b\[[0-9;?]*[ -/]*[@-~]'),
      '',
    );
    expect(painted, contains('↻ Parser refactor — split the tokenizer'));
    expect(painted, contains('(12msg)'));
  });

  test('typing filters live and disk groups by display text', () async {
    // "tok" matches only the disk-a description; enter resumes it.
    final picked = await runPicker([
      CharInput('tok'),
      ControlKey(ControlCode.enter),
    ]);
    expect(picked!.live, isFalse);
    expect(picked.id, 'disk-a');
  });

  test('filter matches live labels too and enter switches', () async {
    final picked = await runPicker([
      CharInput('current'),
      ControlKey(ControlCode.enter),
    ]);
    expect(picked!.live, isTrue);
    expect(picked.id, 'live-1');
  });

  test('esc cancels', () async {
    expect(await runPicker([EscapeKey()]), isNull);
  });
}
