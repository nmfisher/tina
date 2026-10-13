import 'dart:async';
import 'package:tina_console/tina_console.dart';
import 'connection_controls.dart';

/// Keyboard and status presentation only. Both this shortcut and /mode write
/// the same control, which updates the sandbox and process runner together.
final class ModeView implements ConsoleContribution {
  ModeView({required this.mode});
  final ConnectionModeObservation mode;
  ConsoleContext? _console;
  void Function()? _unbind, _unlisten;
  String? _failure;
  @override
  void attachConsole(ConsoleContext context) {
    detachConsole();
    _console = context;
    _unbind = context.bindShortcut((event) {
      if (!mode.canControl ||
          event is! ControlKey ||
          event.code != ControlCode.backtab) return false;
      unawaited(_cycle(context));
      return true;
    });
    _unlisten = context.own(mode.listen((_) => repaintConsole()));
    repaintConsole();
  }

  Future<void> _cycle(ConsoleContext context) async {
    try {
      mode.refresh();
      final expected = mode.mode;
      await mode.setMode(expected.next, expectedMode: expected);
      if (!identical(_console, context)) return;
      _failure = null;
    } catch (error) {
      if (!identical(_console, context)) return;
      _failure = error.toString();
    }
    if (context.isActive) repaintConsole();
  }

  @override
  void repaintConsole() {
    if (_console?.isActive == true)
      _console!.screen.setModeLabel(mode.available
          ? 'mode: ${mode.mode.label}${_failure == null ? '' : ' · $_failure'}'
          : 'mode: unavailable');
  }

  @override
  void detachConsole() {
    _unlisten?.call();
    _unlisten = null;
    _unbind?.call();
    _unbind = null;
    if (_console?.isActive == true) _console?.screen.setModeLabel(null);
    _console = null;
    _failure = null;
  }
}
