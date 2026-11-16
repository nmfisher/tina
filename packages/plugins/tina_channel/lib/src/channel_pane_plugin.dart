import 'package:tina_engine_2/tina_engine_2.dart';

import '../channel_store_api.dart';

/// The presentation-side plugin: opens a second store connection for
/// the pane (WAL readers never block the writer), owns its lifetime
/// with the session, and hands the store to the console view through
/// the interface — the pane never touches sqlite.
///
/// [humanName] is the identity the pane's input line posts under
/// (decided at the composition seam; null means the pane renders
/// read-only — no input line, no member row).
final class ChannelPanePlugin extends AgentPlugin {
  ChannelPanePlugin({required this.openStore, this.humanName});

  final ChannelStoreOpener openStore;

  /// The human's sender name for the pane, or null when the context
  /// has no writable channel identity (the input line renders
  /// disabled).
  final String? humanName;

  ChannelStoreApi? _store;

  /// The store the console view borrows; null before the session
  /// opens. The view reads, joins and posts through the interface; it
  /// must not close this store.
  ChannelStoreApi? get storeForView => _store;

  @override
  String get id => 'tina/channel-tui';

  @override
  SessionSeed? openSession(PluginSession session) {
    _store = openStore();
    return null;
  }

  @override
  void closeSession() {
    _store?.close();
    _store = null;
  }
}
