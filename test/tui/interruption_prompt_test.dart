import 'package:test/test.dart';
import 'package:tina/tui/permission_approval.dart';
import 'package:tina/tui/prompts.dart';
import 'package:tina/tui/spawn_overlay.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_stdio.dart';

void main() {
  test(
    'declining interruption restores approval selection and the draft',
    () async {
      final io = FakeStdio();
      final screen = Screen(io: io, layout: ScreenLayout.fromSize(100, 30));
      final editor = LineEditor(screen: screen);
      addTearDown(editor.close);
      final draft = editor.readLine('> ');
      await pumpEventQueue();
      editor.inject(CharInput('keep this draft'));
      final calls = Invocations();
      final target = calls.create(
        component: const ComponentInfo('a', 'Agent'),
        conversationId: 'c',
      );
      var answered = false;
      final approval = target.run((_) async {
        final answer = await runPermissionApproval(
          screen: screen,
          editor: editor,
          prompt: PermissionPrompt('bash', {'command': 'echo hello'}),
          write: (_) {},
        );
        answered = true;
        return answer;
      });
      await pumpEventQueue();
      editor.inject(ArrowKey(ArrowDirection.down)); // deny once
      await pumpEventQueue();
      final hold = target.hold();
      final choice = runQuestionOverlay(
        screen: screen,
        editor: editor,
        priority: true,
        questions: [
          (text: 'Switch workflow?', options: ['Accept', 'Decline']),
        ],
      );
      await pumpEventQueue();
      expect(answered, isFalse);
      editor.inject(ArrowKey(ArrowDirection.down));
      await pumpEventQueue();
      editor.inject(ControlKey(ControlCode.enter));
      expect(await choice, ['Decline']);
      expect(answered, isFalse);
      await hold.dispose();
      await pumpEventQueue();
      editor.inject(ControlKey(ControlCode.enter));
      expect((await approval).decision, PermissionDecision.deny);
      expect(Prompts.of(editor).active, isNull);
      editor.inject(ControlKey(ControlCode.enter));
      expect(await draft, 'keep this draft');
    },
  );

  test(
    'double Escape cancels both interruption and suspended approval',
    () async {
      final screen = Screen(
        io: FakeStdio(),
        layout: ScreenLayout.fromSize(100, 30),
      );
      final editor = LineEditor(screen: screen);
      addTearDown(editor.close);
      final calls = Invocations();
      editor.onDoubleEscape = () {
        calls.cancelAll();
        return true;
      };
      final target = calls.create(
        component: const ComponentInfo('a', 'Agent'),
        conversationId: 'c',
      );
      final approval = target.run(
        (_) => runPermissionApproval(
          screen: screen,
          editor: editor,
          prompt: PermissionPrompt('bash', {'command': 'echo hello'}),
          write: (_) {},
        ),
      );
      final stopped = expectLater(
        approval,
        throwsA(isA<InvocationCancelled>()),
      );
      await pumpEventQueue();
      final hold = target.hold();
      final choice = runQuestionOverlay(
        screen: screen,
        editor: editor,
        priority: true,
        questions: [
          (text: 'Switch?', options: ['Accept', 'Decline']),
        ],
      );
      await pumpEventQueue();
      editor.inject(EscapeKey());
      editor.inject(EscapeKey());
      expect(await choice, isNull);
      await stopped;
      await hold.dispose();
      expect(Prompts.of(editor).active, isNull);
      expect(editor.isReadingKey, isFalse);
      final next = editor.readLine('> ');
      await pumpEventQueue();
      editor.inject(CharInput('new instruction'));
      editor.inject(ControlKey(ControlCode.enter));
      expect(await next, 'new instruction');
    },
  );
}
