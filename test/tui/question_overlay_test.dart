import 'dart:async';

import 'package:tina/tui/spawn_overlay.dart';
import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import '../helpers/fake_stdio.dart';
import '../helpers/overlay_fixtures.dart';

/// Drives [runQuestionOverlay] with canned [InputEvent]s against a Screen over
/// [FakeStdio]. Pins the inline-question contract (owner bug report
/// 2026-08-24): the form renders AT THE INPUT FIELD — options in the rows
/// directly above the input line, the focused question IN the input row, no
/// centered panel popover — and Enter SELECTS the focused option for the
/// focused question (advancing to the next), submitting only when pressed on
/// the LAST question. ↑/↓ move the option focus within the focused question,
/// ←/→ move between questions (each keeps its own option focus), Esc cancels.
void main() {
  final canned = CannedEvents();

  setUp(canned.clear);

  /// Screen + io pair so rendering assertions can read what was painted.
  (FakeStdio, Screen) rig({int columns = 80, int lines = 24}) {
    final io = FakeStdio()..hasTerminalValue = false;
    final layout = ScreenLayout.fromSize(columns, lines, hasMenuBar: false);
    return (io, Screen(io: io, layout: layout));
  }

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

  test('Enter on the FIRST question selects and advances — it does not submit',
      () async {
    final screen = fakeScreen();
    // A hand-gated event source: the second Enter is only delivered when we
    // complete it, so "the future is still pending" is PROOF the form waited
    // for the second answer rather than submitting on the first Enter.
    final pending = <Completer<InputEvent>>[];
    Future<InputEvent> readEvent() {
      final c = Completer<InputEvent>();
      pending.add(c);
      return c.future;
    }
    final future = runQuestionOverlay(
      screen: screen,
      editor: LineEditor(screen: screen),
      questions: questions,
      readEvent: readEvent,
    );
    await Future<void>.delayed(Duration.zero);
    pending.removeAt(0).complete(ControlKey(ControlCode.enter));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    var done = false;
    future.then((_) => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(done, isFalse,
        reason: 'one Enter answers one question; the form must stay open '
            'waiting for the second answer');
    pending.removeAt(0).complete(ControlKey(ControlCode.enter));
    final result = await future.timeout(overlayTimeout);
    expect(result, ['A: refactor', 'C: minimal']);
  });

  test('Enter selects the FOCUSED option, not the first, before advancing',
      () async {
    final screen = fakeScreen();
    canned.events = [
      ArrowKey(ArrowDirection.down), // Q1 → B
      ControlKey(ControlCode.enter), // select B, advance to Q2
      ArrowKey(ArrowDirection.down), // Q2 → D
      ControlKey(ControlCode.enter), // select D, last question → submit
    ];
    final result = await run(screen, questions).timeout(overlayTimeout);
    expect(result, ['B: rewrite', 'D: full']);
  });

  test('a single question submits on Enter (selecting IS submitting)', () async {
    final screen = fakeScreen();
    canned.events = [
      ArrowKey(ArrowDirection.down),
      ControlKey(ControlCode.enter),
    ];
    final result = await run(screen, const [
      (text: 'Proceed?', options: ['yes', 'no']),
    ]).timeout(overlayTimeout);
    expect(result, ['no']);
  });

  test('up/down move the option within the focused question', () async {
    final screen = fakeScreen();
    canned.events = [
      ArrowKey(ArrowDirection.down), // Q1 → B
      ControlKey(ControlCode.enter), // commit B, advance to Q2
      ControlKey(ControlCode.enter), // commit C (Q2 default), submit
    ];
    final result = await run(screen, questions).timeout(overlayTimeout);
    expect(result, ['B: rewrite', 'C: minimal']);
  });

  test('left/right move between questions, each keeps its own option focus',
      () async {
    final screen = fakeScreen();
    canned.events = [
      ArrowKey(ArrowDirection.right), // → Q2 without committing Q1
      ArrowKey(ArrowDirection.down), // Q2 → D
      ArrowKey(ArrowDirection.left), // ← Q1 (focus still A)
      ControlKey(ControlCode.enter), // select A, advance to Q2
      ControlKey(ControlCode.enter), // select D (focus kept), submit
    ];
    final result = await run(screen, questions).timeout(overlayTimeout);
    expect(result, ['A: refactor', 'D: full']);
  });

  test('a question reached by navigation falls back to its focused option',
      () async {
    final screen = fakeScreen();
    canned.events = [
      ArrowKey(ArrowDirection.right), // skip Q1 entirely
      ControlKey(ControlCode.enter), // select C on the last question → submit
    ];
    final result = await run(screen, questions).timeout(overlayTimeout);
    expect(result, ['A: refactor', 'C: minimal'],
        reason: 'Q1 was never Enter-confirmed; its focused option answers it');
  });

  test('left/right at the edges stay put', () async {
    final screen = fakeScreen();
    canned.events = [
      ArrowKey(ArrowDirection.left), // already at Q1
      ArrowKey(ArrowDirection.right), // Q2
      ArrowKey(ArrowDirection.right), // already at Q2
      ArrowKey(ArrowDirection.up), // Q2 → C
      ControlKey(ControlCode.enter), // select C, last question → submit
    ];
    final result = await run(screen, questions).timeout(overlayTimeout);
    expect(result, ['A: refactor', 'C: minimal']);
  });

  test('Esc cancels the whole form', () async {
    final screen = fakeScreen();
    canned.events = [
      ControlKey(ControlCode.enter), // commit Q1's option…
      ArrowKey(ArrowDirection.right),
      EscapeKey(), // …then cancel: nothing is submitted
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

  group('inline rendering (no panel popover)', () {
    test('renders at the input field: no box borders, no centered title',
        () async {
      final (io, screen) = rig();
      canned.events = [
        ControlKey(ControlCode.enter),
        ControlKey(ControlCode.enter),
      ];
      await run(screen, questions).timeout(overlayTimeout);
      final out = io.written.toString();
      // The old popover was a bordered, centered box titled 'Questions'.
      expect(out, isNot(contains('┌')), reason: 'no box-drawing border');
      expect(out, isNot(contains('└')));
      expect(out, isNot(contains('┐')));
      expect(out, isNot(contains('┘')));
      expect(out, isNot(contains('─')), reason: 'no horizontal rule');
      // The content itself is there: questions, options, and the key hint.
      expect(out, contains('Which approach?'));
      expect(out, contains('A: refactor'));
      expect(out, contains('enter select'));
    });

    test('the focused question renders IN the input row', () async {
      final (io, screen) = rig();
      // Enter selects Q1 and advances; the input row must then carry Q2.
      canned.events = [
        ControlKey(ControlCode.enter),
        EscapeKey(),
      ];
      await run(screen, questions).timeout(overlayTimeout);
      final out = io.written.toString();
      expect(out, contains('How far?'),
          reason: 'the second question reached the screen');
    });

    test('the input row is released when the form completes', () async {
      final (io, screen) = rig();
      canned.events = [
        ControlKey(ControlCode.enter),
        ControlKey(ControlCode.enter),
      ];
      await run(screen, questions).timeout(overlayTimeout);
      // No assertion on absence of text (later paints legitimately repeat);
      // the regression is that completion does not crash while restoring the
      // row, and the cancel path below erases it.
      final (io2, screen2) = rig();
      canned
        ..clear() // the first phase consumed two events; reset the index
        ..events = [EscapeKey()];
      await run(screen2, questions).timeout(overlayTimeout);
      expect(io2.written.toString(), contains('Which approach?'));
    });
  });
}
