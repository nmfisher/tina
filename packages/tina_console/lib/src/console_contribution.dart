import 'input_event.dart';
import 'line_editor.dart';
import 'screen.dart';
import 'modal_surface.dart';
import 'renderer.dart';

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
            ((cancelled) => editor.readKey(
                globalKeys: true,
                panelNavigation: false,
                cancelSignal: cancelled));

  /// Install a live prompt and release only the binding this caller owns.
  void Function() bindPrompt(String Function() builder) {
    final previous = _editor.promptBuilder;
    _editor.promptBuilder = builder;
    return () {
      if (identical(_editor.promptBuilder, builder)) {
        _editor.promptBuilder = previous;
      }
    };
  }

  void refreshInput() => _editor.refresh();

  final _status =
      <Object, ({int priority, List<RenderLine> Function() read})>{};

  /// Each contribution owns only its own lines. Lower priorities appear first
  /// and survive width pressure longer; right-aligned lines retain their slot.
  void Function() bindStatus(List<RenderLine> Function() read,
      {int priority = 100}) {
    final owner = Object();
    _status[owner] = (priority: priority, read: read);
    refreshStatus();
    return () {
      _status.remove(owner);
      refreshStatus();
    };
  }

  void refreshStatus() {
    final sources = _status.values.toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));
    screen.setStatusLines([for (final source in sources) ...source.read()]);
  }

  final LineEditor _editor;
  bool get isReadingKey => _editor.isReadingKey;
  bool get isCompleting => _editor.isCompleting;
  void Function() bindShortcut(bool Function(InputEvent) handler) =>
      _editor.registerShortcut(handler);
  void Function() addModal(ModalSurface modal) {
    _editor.registerModal(modal);
    return () => _editor.unregisterModal(modal);
  }

  final Screen screen;
  final Future<InputEvent?> Function(Future<void> cancelled) readKey;
}

/// An optional owner of transcript presentation. The frontend routes plugin
/// notices here without knowing the renderer's block types or engine events.
abstract interface class ConsoleTranscript {
  void writeNotice(String text);
}
