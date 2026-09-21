import 'package:attractor/attractor.dart';
import 'package:test/test.dart';
import 'package:tina/pipeline/tina_interviewer.dart';
import 'package:tina_console/tina_console.dart';

import '../helpers/overlay_fixtures.dart';

void main() {
  test('cancelling a freeform gate preserves the conversation input owner', () async {
    final screen = fakeScreen();
    final editor = LineEditor(screen: screen);
    addTearDown(editor.close);
    final line = editor.readLine('> ');
    await pumpEventQueue();
    editor.inject(CharInput('draft'));
    final question = TinaInterviewer(screen: screen, editor: editor).ask(
        const Question(text: 'What next?', type: QuestionType.freeform));
    await pumpEventQueue();
    editor.inject(CharInput('unfinished answer'));
    editor.inject(EscapeKey());
    editor.inject(EscapeKey());
    editor.inject(CharInput('replacement'));
    editor.inject(ControlKey(ControlCode.enter));
    expect((await question.timeout(overlayTimeout)).isCancelled, isTrue);
    expect(await line.timeout(overlayTimeout), 'replacement');
    expect(editor.isReadingKey, isFalse);
  });
}
