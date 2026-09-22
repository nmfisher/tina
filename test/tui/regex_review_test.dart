import 'package:test/test.dart';
import 'package:tina/tui/permission_approval.dart';
import 'package:tina/tui/regex_review.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_stdio.dart';

void main() {
  const prompt = PermissionPrompt('bash', {'command': 'git status'});

  test('invalid and nonmatching edits cannot advance to confirmation', () {
    final review = RegexReview(prompt);
    void edit(String text) {
      review.input = TextLineInput(buffer: text, cursor: text.length);
      review.handle(ControlKey(ControlCode.enter));
    }

    edit('[');
    expect(review.reviewing, isFalse);
    expect(review.error, isNotNull);
    edit('git push');
    expect(review.reviewing, isFalse);
    expect(review.error, contains('must match'));
    edit('git (status|diff)');
    expect(review.reviewing, isTrue);
    expect(review.response.rule!.matches(prompt.target), isTrue);
  });

  test(
    'inline rewrite preserves draft and requires a separate confirmation',
    () async {
      final io = FakeStdio();
      final screen = Screen(io: io, layout: ScreenLayout.fromSize(100, 30));
      final editor = LineEditor(screen: screen);
      addTearDown(editor.close);
      final draft = editor.readLine('> ');
      await pumpEventQueue();
      editor.inject(CharInput('keep my draft'));
      final history = StringBuffer();
      var answered = false;
      final pending =
          runPermissionApproval(
            screen: screen,
            editor: editor,
            prompt: prompt,
            write: history.write,
          ).then((value) {
            answered = true;
            return value;
          });
      await pumpEventQueue();
      // The new action is also reachable with the same list navigation.
      for (var i = 0; i < 4; i++) {
        editor.inject(ArrowKey(ArrowDirection.down));
        await pumpEventQueue();
      }
      editor.inject(ControlKey(ControlCode.enter));
      await pumpEventQueue();
      expect(answered, isFalse);
      editor.inject(EditingKey(EditingAction.killToStart));
      await pumpEventQueue();
      editor.inject(PasteInput('git (status|diff)'));
      await pumpEventQueue();
      editor.inject(ControlKey(ControlCode.enter));
      await pumpEventQueue();
      expect(answered, isFalse);
      expect(
        io.written.toString(),
        contains('Allow and save for this conversation'),
      );
      for (var i = 0; i < 3; i++) {
        editor.inject(ScrollEvent(up: i.isEven));
        await pumpEventQueue();
      }
      expect(history.isEmpty, isTrue);
      editor.inject(ControlKey(ControlCode.enter));
      final response = await pending;
      expect(response.rule!.pattern, 'git (status|diff)');
      expect(response.rule!.isRegex, isTrue);
      expect(response.remember, isTrue);
      expect(history.toString().split('┌').length - 1, 1);
      expect(history.toString(), contains('Remember regex:'));
      editor.inject(ControlKey(ControlCode.enter));
      expect(await draft, 'keep my draft');
    },
  );

  for (final reviewing in [false, true]) {
    test(
      'double Escape cancels regex ${reviewing ? 'confirmation' : 'editing'}',
      () async {
        final screen = Screen(
          io: FakeStdio(),
          layout: ScreenLayout.fromSize(100, 30),
        );
        final editor = LineEditor(screen: screen);
        addTearDown(editor.close);
        final pending = runPermissionApproval(
          screen: screen,
          editor: editor,
          prompt: prompt,
          write: (_) {},
        );
        await pumpEventQueue();
        editor.inject(CharInput('r'));
        await pumpEventQueue();
        if (reviewing) {
          editor.inject(ControlKey(ControlCode.enter));
          await pumpEventQueue();
        }
        editor.inject(EscapeKey());
        editor.inject(EscapeKey());
        final response = await pending;
        expect(response.decision, PermissionDecision.deny);
        expect(response.rule, isNull);
        expect(editor.isReadingKey, isFalse);
        final next = editor.readLine('> ');
        await pumpEventQueue();
        editor.inject(CharInput('new instruction'));
        editor.inject(ControlKey(ControlCode.enter));
        expect(await next, 'new instruction');
      },
    );
  }
}
