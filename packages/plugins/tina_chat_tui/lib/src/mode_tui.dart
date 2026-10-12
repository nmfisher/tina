import 'package:tina_console/tina_console.dart';
import 'package:tina_mode/tina_mode.dart';

/// Keyboard and status presentation only. Both this shortcut and /mode write
/// the same control, which updates the sandbox and process runner together.
final class ModeView implements ConsoleContribution {
  ModeView({required this.mode});
  final ModeObservation mode;
  ConsoleContext? _console;
  void Function()? _unbind, _unlisten;
  @override
  void attachConsole(ConsoleContext context) {
    detachConsole();
    _console = context;
    _unbind = context.bindShortcut((event) {
      if (!mode.canControl ||
          event is! ControlKey ||
          event.code != ControlCode.backtab) return false;
      mode.mode = mode.mode.next;
      repaintConsole();
      return true;
    });
    _unlisten = context.own(mode.listen((_) => repaintConsole()));
    repaintConsole();
  }

  @override
  void repaintConsole() {
    if (_console?.isActive == true)
      _console!.screen.setModeLabel('mode: ${mode.mode.label}');
  }

  @override
  void detachConsole() {
    _unlisten?.call();
    _unlisten = null;
    _unbind?.call();
    _unbind = null;
    if (_console?.isActive == true) _console?.screen.setModeLabel(null);
    _console = null;
  }
}
