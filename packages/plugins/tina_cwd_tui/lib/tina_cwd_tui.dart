import 'package:tina_console/tina_console.dart';

/// Displays the session's directory, supplied by the application assembly.
/// Each attachment owns its status binding; no process-global CWD is read.
final class CwdView implements ConsoleContribution {
  CwdView(this.workingDirectory);
  final String workingDirectory;
  ConsoleContext? _console;
  void Function()? _unbind;

  @override
  void attachConsole(ConsoleContext context) {
    detachConsole();
    _console = context;
    _unbind = context.bindStatus(_lines, priority: 20);
  }

  List<RenderLine> _lines() {
    final screen = _console!.screen;
    final path =
        workingDirectory.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ');
    // Leave room for other indicators. Keep the directory's end when the
    // full path is too wide, so the workspace name stays visible.
    final budget = (screen.layout.width ~/ 3 - 5).clamp(1, 10000);
    var label = path;
    if (plainWidth(path) > budget) {
      var remaining = budget - 1;
      final tail = <int>[];
      for (final rune in path.runes.toList().reversed) {
        final width = runeWidth(rune);
        if (width > remaining) break;
        tail.add(rune);
        remaining -= width;
      }
      label = '…${String.fromCharCodes(tail.reversed)}';
    }
    return [
      RenderLine(runs: [RenderRun('cwd: $label', screen.theme.chat.dim)])
    ];
  }

  @override
  void repaintConsole() => _console?.refreshStatus();

  @override
  void detachConsole() {
    _unbind?.call();
    _unbind = null;
    _console = null;
  }
}
