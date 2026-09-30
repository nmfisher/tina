import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_mode/tina_mode.dart';

/// Keyboard and status presentation only. Both this shortcut and /mode write
/// the same control, which updates the sandbox and process runner together.
final class ModeTuiPlugin extends AgentPlugin implements ConsoleContribution {
  ModeTuiPlugin({required this.policy});
  final ModePlugin policy;
  ModeControl get mode => policy;
  ConsoleContext? _console;
  void Function()? _unbind;
  @override
  String get id => policy.id;
  @override
  int get order => policy.order;
  @override
  List<Command> get commands => policy.commands;
  @override
  void attachConsole(ConsoleContext context) {
    detachConsole();
    _console = context;
    _unbind = context.bindShortcut((event) {
      if (event is! ControlKey || event.code != ControlCode.backtab)
        return false;
      mode.mode = mode.mode.next;
      repaintConsole();
      return true;
    });
    repaintConsole();
  }

  @override
  void repaintConsole() {
    if (_console?.isActive == true)
      _console!.screen.setModeLabel('mode: ${mode.mode.label}');
  }

  @override
  void detachConsole() {
    _unbind?.call();
    _unbind = null;
    if (_console?.isActive == true) _console?.screen.setModeLabel(null);
    _console = null;
  }

  @override
  void closeSession() {
    detachConsole();
  }
}
