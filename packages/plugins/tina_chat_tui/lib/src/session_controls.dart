import 'package:tina_console/tina_console.dart';
import 'package:tina_session_controls/tina_session_controls.dart';
export 'package:tina_session_controls/tina_session_controls.dart';

/// A picker and its draft belong to one attachment, independently of the
/// session's model and recent selections.
final class SessionControlsView
    implements ConsoleContribution, ConsoleCommandHandler {
  SessionControlsView(this.controls);
  final SessionControlsObservation controls;
  ConsoleContext? _console;
  void Function()? _paint;
  @override
  Future<void>? handleConsoleCommand(String name, String arguments) {
    final console = _console;
    if (name != 'model' || arguments.trim().isNotEmpty || console == null)
      return null;
    return console.interact(() async {
      if (!console.isActive) return;
      final selected = await _pick(console);
      if (selected != null && _console == console && console.isActive) {
        await controls.select(selected);
        console.refreshInput();
      }
    });
  }

  Future<String?> _pick(ConsoleContext console) async {
    final catalog = controls.catalog;
    final input = console.openInputSession();
    final picker = ModelSearchPicker(
      screen: console.screen,
      modelRefs: catalog.models,
      providerNames: catalog.providerNames,
      modelNames: catalog.modelNames,
      title: 'Switch model',
      recentRefs: [
        controls.recentModels,
        [controls.currentModel]
      ].expand((refs) => refs).toList(),
      readEvent: input.read,
      accent: console.screen.theme.border.focus,
    );
    final paint = picker.repaint;
    _paint = paint;
    try {
      return await picker.run();
    } finally {
      input.dispose();
      if (identical(_paint, paint)) _paint = null;
      if (identical(_console, console) && console.isActive) {
        console.chat.repaint();
        console.refreshInput();
      }
    }
  }

  @override
  void attachConsole(ConsoleContext context) {
    detachConsole();
    _console = context;
  }

  @override
  void detachConsole() {
    _console = null;
    _paint = null;
  }

  @override
  void repaintConsole() => _paint?.call();
}
