import 'input_event.dart';
import 'line_editor.dart';
import 'screen.dart';
import 'modal_surface.dart';
import 'renderer.dart';
import 'region.dart';
import 'console_workspace.dart';

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
        _shared = _ConsoleBindings(editor),
        _chat = null,
        _active = null,
        _activate = null,
        panels = null,
        readKey = readKey ??
            ((cancelled) => editor.readKey(
                globalKeys: true,
                panelNavigation: false,
                cancelSignal: cancelled));

  ConsoleContext._view(ConsoleContext parent, this._chat, this._active,
      this._activate, this.panels)
      : screen = parent.screen,
        _editor = parent._editor,
        _shared = parent._shared,
        readKey = parent.readKey;

  ConsoleContext forView(
          {required ScrollingTextRegion chat,
          required bool Function() isActive,
          required void Function() activate,
          required ConsolePanels panels}) =>
      ConsoleContext._view(this, chat, isActive, activate, panels);

  final _ConsoleBindings _shared;
  final ScrollingTextRegion? _chat;
  final bool Function()? _active;
  final void Function()? _activate;
  final ConsolePanels? panels;
  ScrollingTextRegion get chat => _chat ?? screen.chat;
  bool get isActive => _active?.call() ?? true;
  LineEditor get input => _editor;

  /// Serialize complete interactions across views and keep the requesting
  /// view focused until its dialog has released the shared input owner.
  Future<T> interact<T>(Future<T> Function() action) {
    final run = _shared.interactions.then((_) async {
      _activate?.call();
      final focus = _editor.focusManager;
      _editor.focusManager = null;
      try {
        return await action();
      } finally {
        _editor.focusManager = focus;
        refreshInput();
      }
    });
    _shared.interactions = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// Install a live prompt and release only the binding this caller owns.
  void Function() bindPrompt(String Function() builder) {
    final owner = Object();
    _shared.prompts[owner] = () => isActive ? builder() : null;
    _editor.promptBuilder = _shared.prompt;
    return () {
      _shared.prompts.remove(owner);
      if (_shared.prompts.isEmpty)
        _editor.promptBuilder = _shared.originalPrompt;
    };
  }

  void refreshInput() {
    if (isActive) _editor.refresh();
  }

  /// Each contribution owns only its own lines. Lower priorities appear first
  /// and survive width pressure longer; right-aligned lines retain their slot.
  void Function() bindStatus(List<RenderLine> Function() read,
      {int priority = 100}) {
    final owner = Object();
    _shared.status[owner] =
        (priority: priority, read: () => isActive ? read() : []);
    refreshStatus();
    return () {
      _shared.status.remove(owner);
      refreshStatus();
    };
  }

  void refreshStatus() {
    final sources = _shared.status.values.toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));
    screen.setStatusLines([for (final source in sources) ...source.read()]);
  }

  final LineEditor _editor;
  bool get isReadingKey => _editor.isReadingKey;
  bool get isCompleting => _editor.isCompleting;
  void Function() bindShortcut(bool Function(InputEvent) handler) =>
      _editor.registerShortcut((event) => isActive && handler(event));
  void Function() addModal(ModalSurface modal) {
    final scoped = _ScopedModal(this, modal);
    _editor.registerModal(scoped);
    return () => _editor.unregisterModal(scoped);
  }

  final Screen screen;
  final Future<InputEvent?> Function(Future<void> cancelled) readKey;
}

final class _ConsoleBindings {
  _ConsoleBindings(LineEditor editor) : originalPrompt = editor.promptBuilder;
  final String Function()? originalPrompt;
  final prompts = <Object, String? Function()>{};
  final status = <Object, ({int priority, List<RenderLine> Function() read})>{};
  Future<void> interactions = Future.value();
  String prompt() {
    for (final build in prompts.values.toList().reversed) {
      final value = build();
      if (value != null) return value;
    }
    return originalPrompt?.call() ?? '› ';
  }
}

final class _ScopedModal extends ModalSurface {
  _ScopedModal(this.context, this.inner);
  final ConsoleContext context;
  final ModalSurface inner;
  @override
  bool get isActive => context.isActive && inner.isActive;
  @override
  bool handleEvent(InputEvent event) => inner.handleEvent(event);
}

/// An optional owner of transcript presentation. The frontend routes plugin
/// notices here without knowing the renderer's block types or engine events.
abstract interface class ConsoleTranscript {
  void writeNotice(String text);
}
