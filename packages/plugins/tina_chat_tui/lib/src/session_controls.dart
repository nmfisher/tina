import 'package:tina_console/tina_console.dart';
import 'package:tina_rewind/tina_rewind.dart';
import 'connection_controls.dart';
export 'package:tina_session_controls/observation.dart';

/// A picker and its draft belong to one attachment, independently of the
/// session's model and recent selections.
final class SessionControlsView
    implements
        ConsoleContribution,
        ConsoleCommandHandler,
        OffersConsoleWhileRunning {
  SessionControlsView(this.controls);
  final ConnectionSessionControls controls;
  ConsoleContext? _console;
  void Function()? _paint, _unlisten;
  @override
  Future<void>? handleConsoleCommand(String name, String arguments) {
    final console = _console;
    if (!controls.canControl || console == null) return null;
    if (name == 'rewind' && arguments.trim().isEmpty) {
      return console.interact(() async {
        if (!console.isActive) return;
        controls.refresh();
        if (!controls.available) throw StateError('Rewind is unavailable.');
        final points = controls.rewindPoints;
        if (points.isEmpty) {
          _notice(console, 'Nothing to rewind to yet.');
          return;
        }
        final expectedHead = controls.rewindHead;
        final selected = await _pickRewind(console, points);
        if (selected == null) return; // cancelled: the session is untouched
        if (_console == console && console.isActive) {
          try {
            await controls.rewind(selected.toSeq, expectedHead: expectedHead);
          } on StateError catch (error) {
            _notice(console, error.message);
            return;
          }
          console.refreshInput();
        }
      });
    }
    if (name != 'model' || arguments.trim().isNotEmpty) return null;
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

  void _notice(ConsoleContext console, String text) {
    console.chat.writeLine(RegionLine(text));
    console.refreshInput();
  }

  Future<RewindPoint?> _pickRewind(
      ConsoleContext console, List<RewindPoint> points) async {
    final input = console.openInputSession();
    try {
      final index = await runListPickerOverlay(
        screen: console.screen,
        title: 'Rewind conversation',
        items: [
          for (var i = 0; i < points.length; i++)
            ListPickerItem(
              points[i].kind == 'compaction'
                  ? '${points[i].label}  [compaction]'
                  : points[i].label,
              detail: '${i + 1}  ${_clock(points[i].at)}',
            ),
        ],
        contextLine:
            'Rewinding removes the chosen message and everything after it.',
        footer: '↑↓ move · Enter rewind here · Esc cancel',
        readEvent: input.read,
        accent: console.screen.theme.border.focus,
      );
      return index == null ? null : points[index];
    } finally {
      input.dispose();
      if (identical(_console, console) && console.isActive) {
        console.chat.repaint();
        console.refreshInput();
      }
    }
  }

  static String _clock(String at) {
    final time = DateTime.tryParse(at)?.toLocal();
    if (time == null) return '';
    final two = (int v) => v.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}';
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
