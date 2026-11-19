import 'dart:async';

import '../channel_store_api.dart';

/// The read-only chat lifecycle a dependent (the pane plugin) sees:
/// whether this session's chat has been started — chats are OPT-IN,
/// nothing exists until the user approved one — and the one-way signal
/// when it starts, mid-session.
///
/// The capability's provider is the channel plugin itself (the plugin
/// registry resolves capabilities by typing the plugin instance), so
/// this is the narrow face it exposes; the mutable side stays private
/// to it ([SessionChat] is the standalone implementation tests and
/// default compositions use).
abstract interface class SessionChatLifecycle {
  /// Whether this session's chat has been started (created in this
  /// process, or found existing at session open).
  bool get isStarted;

  /// Fires once, when the chat is started. Listeners that attach after
  /// the fact read [isStarted] instead.
  Stream<void> get changes;
}

/// A mutable [SessionChatLifecycle]: started is one-way (a chat never
/// un-starts — `closeSession` ends the whole session instead).
final class SessionChat implements SessionChatLifecycle {
  final _changes = StreamController<void>.broadcast();
  bool _started = false;

  @override
  bool get isStarted => _started;

  @override
  Stream<void> get changes => _changes.stream;

  /// Marks the chat started and notifies listeners. Idempotent: the
  /// second call is a no-op.
  void markStarted() {
    if (_started) return;
    _started = true;
    _changes.add(null);
  }

  /// Releases the signal; called when the session closes.
  void dispose() => _changes.close();
}

/// What the pane view reads: the pane's OWN store connection once the
/// session's chat has been started, whether it exists yet, and the
/// signal when it appears. The pane binds nothing while no chat
/// exists, and goes live (pane opens) at the start signal.
abstract interface class ChannelPaneChat {
  /// The pane's store connection, or null before the chat is started.
  ChannelStoreApi? get store;

  /// Whether [store] is available.
  bool get isStarted;

  /// Fires when the store appears (once per session).
  Stream<void> get changes;
}

/// The mutable [ChannelPaneChat] the pane plugin owns: dormant (no
/// store) until the session's chat is started, then holding the pane's
/// own connection for the rest of the session.
final class LivePaneChat implements ChannelPaneChat {
  LivePaneChat();

  /// A handle that is already started (tests, compositions whose chat
  /// predates the view).
  LivePaneChat.started(ChannelStoreApi store) : _store = store;

  ChannelStoreApi? _store;
  final _changes = StreamController<void>.broadcast();

  @override
  ChannelStoreApi? get store => _store;

  @override
  bool get isStarted => _store != null;

  @override
  Stream<void> get changes => _changes.stream;

  /// Publishes the pane's store connection and fires the signal once.
  /// Idempotent: the pane keeps one connection per session.
  void attach(ChannelStoreApi store) {
    if (_store != null) return;
    _store = store;
    _changes.add(null);
  }

  /// Ends the signal and drops the store; called when the session
  /// closes.
  void detach() {
    _store = null;
    _changes.close();
  }
}
