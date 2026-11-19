import 'dart:async';

import 'package:tina_engine_2/tina_engine_2.dart';

import '../channel_store_api.dart';
import 'session_chat.dart';

/// The presentation-side plugin: owns a second connection to the
/// session's own chat store (WAL readers never block the writer) and
/// hands it to the console view through the interface — the pane never
/// touches sqlite. The pane shows this session's chat; other sessions'
/// chats are other files it never sees.
///
/// The chat is OPT-IN: until one is started (the user approved a
/// `channel_start`), this plugin opens nothing and the view binds
/// nothing — no pane, no pill. [chat] is the shared [SessionChat]
/// signal from the channel plugin (the registry's capability wiring
/// hands it in): when the chat starts, mid-session, the pane opens its
/// own connection and the view goes live. A chat that already existed
/// at session open (resume) is already marked started, so the pane
/// attaches immediately.
///
/// [humanName] is the identity the pane's input line posts under
/// (decided at the composition seam; null means the pane renders
/// read-only — no input line, no member row).
final class ChannelPanePlugin extends AgentPlugin {
  ChannelPanePlugin({required this.openStore, this.humanName, SessionChatLifecycle? chat})
      : _chat = chat ?? SessionChat();

  final ChannelStoreOpener openStore;

  /// The human's sender name for the pane, or null when the context
  /// has no writable channel identity (the input line renders
  /// disabled).
  final String? humanName;

  /// The session's chat lifecycle, shared with the channel plugin.
  final SessionChatLifecycle _chat;

  StreamSubscription<void>? _subscription;
  String? _scope;
  ChannelStoreApi? _store;
  final LivePaneChat _paneChat = LivePaneChat();

  /// The pane's live chat handle for the console view: the store once
  /// the chat has been started, whether it exists yet, and the signal
  /// when it appears.
  ChannelPaneChat get chatForView => _paneChat;

  /// The store the console view borrows; null until the session's chat
  /// is started. The view reads, joins and posts through the
  /// interface; it must not close this store.
  ChannelStoreApi? get storeForView => _store;

  @override
  String get id => 'tina/channel-tui';

  @override
  SessionSeed? openSession(PluginSession session) {
    _scope = session.id;
    // Subscribe BEFORE checking the flag, so a chat started between
    // the two lines still fires the event.
    _subscription = _chat.changes.listen((_) => _openStore());
    if (_chat.isStarted) _openStore();
    return null;
  }

  void _openStore() {
    final scope = _scope;
    if (_store != null || scope == null) return;
    _store = openStore(scope);
    // The pane appears when the view sees this handle change.
    _paneChat.attach(_store!);
  }

  @override
  void closeSession() {
    _subscription?.cancel();
    _subscription = null;
    _scope = null;
    _paneChat.detach();
    _store?.close();
    _store = null;
  }
}
