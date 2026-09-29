import 'input_event.dart';
import 'line_editor.dart';
import 'screen.dart';
import 'modal_surface.dart';
import 'renderer.dart';
import 'region.dart';
import 'console_workspace.dart';
import 'settings_contribution.dart';

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
        _settings = SettingsRegistry(),
        panels = null,
        readKey = readKey ??
            ((cancelled) => editor.readKey(
                globalKeys: true,
                panelNavigation: false,
                cancelSignal: cancelled));

  ConsoleContext._view(ConsoleContext parent, this._chat, this._active,
      this._activate, this.panels,
      {SettingsRegistry? settings})
      : screen = parent.screen,
        _editor = parent._editor,
        _shared = parent._shared,
        _settings = settings ?? SettingsRegistry(),
        readKey = parent.readKey;

  ConsoleContext _forAttachment() =>
      ConsoleContext._view(this, _chat, _active, _activate, panels,
          settings: _settings);

  final _releases = <void Function()>[];
  bool _disposed = false;
  final SettingsRegistry _settings;
  late final SettingsRegistry settings = _settings.scoped(own);

  /// Track another UI resource with this attachment. The returned release is
  /// idempotent; all remaining releases run even when plugin teardown throws.
  void Function() own(void Function() release) {
    if (_disposed) throw StateError('console attachment is disposed');
    var released = false;
    late final void Function() dispose;
    dispose = () {
      if (released) return;
      released = true;
      _releases.remove(dispose);
      release();
    };
    _releases.add(dispose);
    return dispose;
  }

  void _dispose() {
    _disposed = true;
    Object? failure;
    for (final release in _releases.toList().reversed) {
      try {
        release();
      } catch (error) {
        failure ??= error;
      }
    }
    if (failure != null) throw failure;
  }

  void _checkOpen() {
    if (_disposed) throw StateError('console attachment is disposed');
  }

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
  bool get isActive => !_disposed && (_active?.call() ?? true);
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
    _checkOpen();
    final owner = Object();
    _shared.prompts[owner] = () => isActive ? builder() : null;
    _editor.promptBuilder = _shared.prompt;
    return own(() {
      _shared.prompts.remove(owner);
      if (_shared.prompts.isEmpty)
        _editor.promptBuilder = _shared.originalPrompt;
    });
  }

  void refreshInput() {
    if (isActive) _editor.refresh();
  }

  /// Each contribution owns only its own lines. Lower priorities appear first
  /// and survive width pressure longer; right-aligned lines retain their slot.
  void Function() bindStatus(List<RenderLine> Function() read,
      {int priority = 100}) {
    _checkOpen();
    final owner = Object();
    _shared.status[owner] =
        (priority: priority, read: () => isActive ? read() : []);
    final release = own(() {
      _shared.status.remove(owner);
      refreshStatus();
    });
    refreshStatus();
    return release;
  }

  void refreshStatus() {
    final sources = _shared.status.values.toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));
    screen.setStatusLines([for (final source in sources) ...source.read()]);
  }

  final LineEditor _editor;
  bool get isReadingKey => _editor.isReadingKey;
  bool get isCompleting => _editor.isCompleting;
  void Function() bindShortcut(bool Function(InputEvent) handler) {
    _checkOpen();
    return own(_editor.registerShortcut((event) => isActive && handler(event)));
  }

  void Function() addModal(ModalSurface modal) {
    _checkOpen();
    final scoped = _ScopedModal(this, modal);
    _editor.registerModal(scoped);
    return own(() => _editor.unregisterModal(scoped));
  }

  final Screen screen;
  final Future<InputEvent?> Function(Future<void> cancelled) readKey;
}

/// One contribution's attachment lifetime, including failed activation.
final class ConsoleAttachment {
  ConsoleAttachment._(this.contribution, this.context);
  final ConsoleContribution contribution;
  final ConsoleContext context;
  bool _closed = false;

  static ConsoleAttachment attach(
      ConsoleContribution contribution, ConsoleContext parent) {
    final attachment =
        ConsoleAttachment._(contribution, parent._forAttachment());
    try {
      contribution.attachConsole(attachment.context);
      return attachment;
    } catch (_) {
      try {
        attachment.dispose();
      } catch (_) {/* Preserve activation error. */}
      rethrow;
    }
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    try {
      contribution.detachConsole();
    } finally {
      context._dispose();
    }
  }
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
