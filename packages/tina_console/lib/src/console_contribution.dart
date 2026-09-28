import 'input_event.dart';
import 'line_editor.dart';
import 'screen.dart';
import 'modal_surface.dart';

/// A frontend contribution mounted by the application without feature knowledge.
abstract interface class ConsoleContribution {
  void attachConsole(ConsoleContext context);
  void repaintConsole();
  void detachConsole();
}

/// Explicit frontend capabilities. Key reads share the editor's input owner.
final class ConsoleContext {
  ConsoleContext(
      {required this.screen,
      required LineEditor editor,
      Future<InputEvent?> Function(Future<void> cancelled)? readKey})
      : _editor = editor,
        readKey = readKey ??
            ((cancelled) =>
                editor.readKey(globalKeys: true, cancelSignal: cancelled));
  final LineEditor _editor;
  bool get isReadingKey => _editor.isReadingKey;
  void Function() bindShortcut(bool Function(InputEvent) handler) =>
      _editor.registerShortcut(handler);
  void Function() addModal(ModalSurface modal) {
    _editor.registerModal(modal);
    return () => _editor.unregisterModal(modal);
  }

  final Screen screen;
  final Future<InputEvent?> Function(Future<void> cancelled) readKey;
}
