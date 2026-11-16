import 'package:tina_engine_2/tina_engine_2.dart';

import '../channel_store_api.dart';

/// The presentation-side plugin: opens a second store connection for
/// the pane (WAL readers never block the writer), owns its lifetime
/// with the session, and hands the store to the console view through
/// the interface — the pane never touches sqlite.
final class ChannelPanePlugin extends AgentPlugin {
  ChannelPanePlugin({required this.openStore});

  final ChannelStoreOpener openStore;

  ChannelStoreApi? _store;

  /// The store the console view borrows; null before the session
  /// opens. Read-only by convention; the view must not close it.
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
