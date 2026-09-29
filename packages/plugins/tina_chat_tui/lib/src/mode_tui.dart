import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tools/tina_tools.dart';

/// Keyboard and status presentation only. Both this shortcut and /mode write
/// the same control, which updates the sandbox and process runner together.
final class ModeTuiPlugin extends AgentPlugin implements ConsoleContribution {
  ModeTuiPlugin({required this.mode});
  final ModeControl mode;
  ConsoleContext? _console;
  void Function()? _unbind;
  @override
  String get id => 'tina/mode-tui';
  @override
  void attachConsole(ConsoleContext context) {
    detachConsole();
    _console = context;
    _unbind = context.bindShortcut((event) {
      if (event is! ControlKey || event.code != ControlCode.backtab)
        return false;
      mode.mode = mode.mode == PermissionMode.normal
          ? PermissionMode.readOnly
          : PermissionMode.normal;
      repaintConsole();
      return true;
    });
    repaintConsole();
  }

  @override
  void repaintConsole() {
    if (_console?.isActive == true)
      _console!.screen
          .setModeLabel('mode: ${ModeCommandPlugin.wordFor(mode.mode)}');
  }

  @override
  void detachConsole() {
    _unbind?.call();
    _unbind = null;
    if (_console?.isActive == true) _console?.screen.setModeLabel(null);
    _console = null;
  }

  @override
  void closeSession() => detachConsole();
}
