import 'package:tina_console/tina_console.dart';
import 'connection_controls.dart';
export 'package:tina_session_controls/observation.dart';

/// A picker and its draft belong to one attachment, independently of the
/// session's model and recent selections.
final class SessionControlsView
    implements ConsoleContribution, ConsoleCommandHandler {
  SessionControlsView(this.controls);
  final ConnectionSessionControls controls;
  ConsoleContext? _console;
  void Function()? _paint, _unlisten;
  @override
  Future<void>? handleConsoleCommand(String name, String arguments) {
    final console = _console;
    if (!controls.canControl ||
        name != 'model' ||
        arguments.trim().isNotEmpty ||
        console == null) return null;
    return console.interact(() async {
      if (!console.isActive) return;
      controls.refresh();
      if (!controls.available) throw StateError('Model controls unavailable.');
      final expectedModel = controls.currentModel;
      final selected = await _pick(console);
      if (selected != null && _console == console && console.isActive) {
        await controls.select(selected, expectedModel: expectedModel);
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
    _unlisten = context.own(controls.listen(() {}));
  }

  @override
  void detachConsole() {
    _unlisten?.call();
    _unlisten = null;
    _console = null;
    _paint = null;
  }

  @override
  void repaintConsole() => _paint?.call();
}
