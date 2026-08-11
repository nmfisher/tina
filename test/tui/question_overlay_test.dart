import 'package:tina/tui/spawn_overlay.dart';
import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import '../helpers/overlay_fixtures.dart';

/// Drives [runQuestionOverlay] with canned [InputEvent]s against a Screen over
/// [FakeStdio]. Pins the opencode-style navigation contract: ↑/↓ move the
/// option focus within the focused question, ←/→ move between questions (each
/// keeps its own option focus), Enter confirms ALL questions at once, Esc
/// cancels.
void main() {
  final canned = CannedEvents();

  setUp(canned.clear);

  Future<List<String>?> run(
    Screen screen,
    List<({String text, List<String> options})> questions,
  ) =>
      runQuestionOverlay(
        screen: screen,
        editor: LineEditor(screen: screen),
        questions: questions,
        readEvent: canned.readEvent,
      );

  const questions = [
    (text: 'Which approach?', options: ['A: refactor', 'B: rewrite']),
    (text: 'How far?', options: ['C: minimal', 'D: full']),
  ];

  test('Enter confirms the default (first option of each question)', () async {
    final screen = fakeScreen();
    canned.events = [ControlKey(ControlCode.enter)];
    final result = await run(screen, questions).timeout(overlayTimeout);
    expect(result, ['A: refactor', 'C: minimal']);
  });

  test('up/down move the option within the focused question', () async {
    final screen = fakeScreen();
    canned.events = [
      ArrowKey(ArrowDirection.down), // Q1 → B
      ControlKey(ControlCode.enter),
    ];
    final result = await run(screen, questions).timeout(overlayTimeout);
    expect(result, ['B: rewrite', 'C: minimal']);
  });

  test('left/right move between questions, each keeps its own option focus',
      () async {
    final screen = fakeScreen();
    canned.events = [
      ArrowKey(ArrowDirection.down), // Q1 → B
      ArrowKey(ArrowDirection.right), // → Q2
      ArrowKey(ArrowDirection.down), // Q2 → D
      ArrowKey(ArrowDirection.left), // ← Q1 (focus still B)
      ArrowKey(ArrowDirection.up), // Q1 → A
      ArrowKey(ArrowDirection.right), // → Q2 (focus still D)
      ControlKey(ControlCode.enter),
    ];
    final result = await run(screen, questions).timeout(overlayTimeout);
    expect(result, ['A: refactor', 'D: full']);
  });

  test('left/right at the edges stay put', () async {
    final screen = fakeScreen();
    canned.events = [
      ArrowKey(ArrowDirection.left), // already at Q1
      ArrowKey(ArrowDirection.right), // Q2
      ArrowKey(ArrowDirection.right), // already at Q2
      ArrowKey(ArrowDirection.up), // Q2 → C
      ControlKey(ControlCode.enter),
    ];
    final result = await run(screen, questions).timeout(overlayTimeout);
    expect(result, ['A: refactor', 'C: minimal']);
  });

  test('Esc cancels the whole form', () async {
    final screen = fakeScreen();
    canned.events = [
      ArrowKey(ArrowDirection.down),
      ArrowKey(ArrowDirection.right),
      EscapeKey(),
    ];
    final result = await run(screen, questions).timeout(overlayTimeout);
    expect(result, isNull);
  });

  test('many options scroll without losing the return value', () async {
    final screen = fakeScreen();
    final many = [
      (
        text: 'Pick one',
        options: [for (var i = 0; i < 20; i++) 'option $i'],
      ),
    ];
    // Jump from option 0 to option 19 (past the visible window).
    canned.events = [
      for (var i = 0; i < 19; i++) ArrowKey(ArrowDirection.down),
      ControlKey(ControlCode.enter),
    ];
    final result = await run(screen, many).timeout(overlayTimeout);
    expect(result, ['option 19']);
  });

  test('an empty question list returns an empty list, not a crash', () async {
    final screen = fakeScreen();
    canned.events = [ControlKey(ControlCode.enter)];
    final result = await run(screen, const []).timeout(overlayTimeout);
    expect(result, isEmpty);
  });
}
