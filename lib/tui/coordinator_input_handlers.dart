import 'package:tina/session_controller.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina_console/tina_console.dart';

/// The dependencies the input-state and permission-mode handlers in
/// [wireInputStateHandlers] touch. Explicit fields instead of the create()
/// closure's implicit captures: this wiring is now reviewable on its own.
class InputStateHandlerDeps {
  final LineEditor editor;
  final PermissionPolicy policy;
  final SubAgentScheduler scheduler;
  final SessionManager sessionManager;
  final Screen screen;

  const InputStateHandlerDeps({
    required this.editor,
    required this.policy,
    required this.scheduler,
    required this.sessionManager,
    required this.screen,
  });
}

/// Wire the controller's per-session draft input, the slow-command input
/// capture window, and the live `/permissions <mode>` flip.
///
/// Each handler only mutates state it receives through [deps] — nothing here
/// reads or changes the coordinator's other wiring, so this block can move
/// out of the closure factory without changing any capture semantics.
void wireInputStateHandlers(
  SessionController controller,
  InputStateHandlerDeps deps,
) {
  final editor = deps.editor;
  final policy = deps.policy;
  final scheduler = deps.scheduler;
  final sessionManager = deps.sessionManager;
  final screen = deps.screen;

  // Per-session draft input: a half-typed prompt survives switching to
  // another session and back. A command being typed isn't a draft — only
  // real prompt text is preserved.
  controller.saveInput = () {
    if (!editor.isEditing) return null;
    final state = editor.editState;
    if (state.buffer.trimLeft().startsWith('/')) {
      return (buffer: '', cursor: 0);
    }
    return state;
  };
  controller.restoreInput = (buffer, cursor) {
    editor.loadEditState(buffer, cursor);
  };
  // tin-y8kh: while a slow command dispatch runs (e.g. /compact
  // summarizing through an LLM call), the editor's queue-mode capture
  // takes keystrokes instead of dropping them; the controller flushes the
  // captured lines through the normal dispatch path when the
  // command settles.
  controller.beginInputCapture = (onSubmit, queueCount) =>
      editor.beginInputCaptureWindow(onSubmit, queueCount: queueCount);
  controller.endInputCapture = editor.endInputCaptureWindow;
  // `/permissions <mode>`: flip the shared base policy plus every live
  // conversation's policy (they're copies). New conversations inherit from
  // the base policy; already-built agents consult their policy per check,
  // so the change applies immediately.
  controller.setPermissionMode = (mode) {
    policy.mode = mode;
    scheduler.basePolicy?.mode = mode;
    for (final session in sessionManager.all) {
      for (final conv in session.conversations) {
        conv.policy.mode = mode;
      }
    }
    screen.setModeLabel('mode: ${policy.mode.label}');
  };
}
