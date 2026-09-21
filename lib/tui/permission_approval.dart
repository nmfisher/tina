import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';

import 'spawn_overlay.dart';

/// One approval UI for conversations and workflow nodes. The engine supplies
/// both the visible choices and their grant scopes.
Future<PermissionResponse> runPermissionApproval({
  required Screen screen,
  required LineEditor editor,
  required PermissionPrompt prompt,
  required void Function(String text) write,
}) async {
  final cancel = Future.any<void>([
    editor.inputCancelled,
    if (prompt.cancelSignal != null) prompt.cancelSignal!,
  ]);
  write('  approve?\n');
  var acknowledged = false;
  final choices = prompt.choices;
  final labels = [for (final choice in choices) '[${choice.key}] ${choice.label}'];
  final answers = await runQuestionOverlay(
    screen: screen,
    editor: editor,
    questions: [
      (text: 'Approve ${prompt.toolName}?', options: labels),
    ],
    footer: '  ↑↓ move · enter select · esc deny · esc esc stop',
    readEvent: () => editor.readKey(
      globalKeys: true,
      panelNavigation: false,
      cancelSignal: cancel,
    ),
    shortcut: (event) {
      if (event is CharInput) {
        final choice = prompt.choiceForKey(event.text);
        if (choice != null) {
          return choices.indexWhere((entry) => entry.key == choice.key);
        }
      }
      if (event is ControlKey && event.code == ControlCode.backtab) {
        editor.onBackTab?.call();
      } else if (event is! ArrowKey &&
          !(event is ControlKey && event.code == ControlCode.enter) &&
          !acknowledged) {
        acknowledged = true;
        write(ignoredKeyAck);
      }
      return null;
    },
  );
  final choice = answers == null ? null : choices[labels.indexOf(answers.single)];
  write(choice == null ? '  approval cancelled\n' : '  ${choice.label}\n');
  return choice?.response ?? PermissionResponse.denyOnce;
}
