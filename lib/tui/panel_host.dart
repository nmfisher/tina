import 'package:tina_console/tina_console.dart';

import 'panel_manager.dart';

/// Panel identity is independent of conversation or workflow identity.
typedef PanelSpec = ({String id, String label, PanelPlacement placement});

enum PanelPlacement { sideColumn }

/// A view owned by [PanelHost]. Closing it releases its UI resources; the
/// caller decides whether a backing job or process should also stop.
class OpenedPanel {
  OpenedPanel._(this.frame, this.content, this._onDispose);

  final PanelFrame frame;
  final PanelContent content;
  final void Function()? _onDispose;
  bool _closed = false;
  bool get isClosed => _closed;

  void setFinished() {
    if (!_closed) frame.setBusy(false);
  }
}

/// Creates and removes arbitrary panel content without constructing a chat
/// host, interpreting workflow events, or requiring a conversation.
///
/// The binding callbacks connect to the application's content coordinator;
/// [refreshLayout] applies its split policy after registration changes. This
/// keeps session-specific presentation outside the panel lifecycle.
class PanelHost {
  PanelHost({
    required this.panelManager,
    required this.bindContent,
    required this.unbindContent,
    required this.refreshLayout,
  });

  final PanelManager panelManager;
  final void Function({
    required PanelFrame frame,
    required PanelContent content,
  })
  bindContent;
  final void Function(PanelFrame frame) unbindContent;
  final void Function() refreshLayout;
  Screen get screen => panelManager.screen;

  final Map<String, OpenedPanel> _panels = {};
  bool _disposed = false;
  OpenedPanel? panelFor(String id) => _panels[id];

  /// Reject duplicate IDs before a content factory allocates resources.
  void ensureAvailable(String id) {
    if (_disposed) throw StateError('Panel host has been disposed');
    if (id.isEmpty) throw ArgumentError.value(id, 'id', 'must not be empty');
    if (_panels.containsKey(id) ||
        panelManager.allFrames.any((frame) => frame.conversationId == id)) {
      throw StateError('Panel already exists: $id');
    }
  }

  /// Takes ownership of [content] after validating [spec]. Registration is
  /// synchronous; it does not steal focus. [onDispose] releases view-specific
  /// subscriptions exactly once, on close, shutdown, or failed registration.
  OpenedPanel openPanel(
    PanelSpec spec, {
    required PanelContent content,
    PanelInputMode inputMode = PanelInputMode.readOnly,
    bool Function(InputEvent event)? onInput,
    void Function()? onDispose,
  }) {
    ensureAvailable(spec.id);
    if (inputMode == PanelInputMode.sharedEditor) {
      throw ArgumentError(
        'Shared editor panels require a conversation binding',
      );
    }
    final frame = PanelFrame(
      screen: screen,
      label: spec.label,
      conversationId: spec.id,
      inputMode: inputMode,
    )..onPanelKey = onInput;
    final opened = OpenedPanel._(frame, content, onDispose);
    _panels[spec.id] = opened;
    panelManager.tree.parentOf[spec.id] = panelManager.tree.rootId;
    panelManager.tree.baseLabel[spec.id] = spec.label;
    try {
      bindContent(frame: frame, content: content);
      refreshLayout();
      return opened;
    } catch (error, stack) {
      try {
        closePanel(opened);
      } catch (_) {
        // Keep the registration error as the cause; close attempts every
        // cleanup step even when an individual resource fails to release.
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  /// Identity-checked and idempotent: an old handle cannot close a replacement
  /// panel that reused its ID. Hooks are removed before detaching surfaces.
  void closePanel(OpenedPanel handle) {
    final frame = handle.frame;
    if (_panels[frame.conversationId] != handle) return;
    _panels.remove(frame.conversationId);
    handle._closed = true;
    frame.onPanelKey = null;
    frame.onScroll = null;
    frame.onWheel = null;
    frame.onFocus = null;
    frame.onHighlight = null;
    Object? failure;
    StackTrace? stack;
    void release(void Function() action) {
      try {
        action();
      } catch (error, trace) {
        failure ??= error;
        stack ??= trace;
      }
    }

    release(() => handle._onDispose?.call());
    release(() => unbindContent(frame));
    release(() {
      if (!handle.content.isDetached) handle.content.detach();
    });
    panelManager.tree.parentOf.remove(frame.conversationId);
    panelManager.tree.baseLabel.remove(frame.conversationId);
    release(() => panelManager.removeFrame(frame));
    if (!_disposed) release(refreshLayout);
    if (failure != null) Error.throwWithStackTrace(failure!, stack!);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    Object? failure;
    StackTrace? stack;
    for (final panel in _panels.values.toList()) {
      try {
        closePanel(panel);
      } catch (error, trace) {
        failure ??= error;
        stack ??= trace;
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, stack!);
  }
}
