import 'input_event.dart';
import 'line_editor.dart';
import 'screen.dart';

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
      : readKey = readKey ??
            ((cancelled) =>
                editor.readKey(globalKeys: true, cancelSignal: cancelled));
  final Screen screen;
  final Future<InputEvent?> Function(Future<void> cancelled) readKey;
}
