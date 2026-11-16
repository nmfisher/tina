import 'package:tina_engine_2/tina_engine_2.dart';

import '../channel_store_api.dart';
import 'channel_tools.dart';

/// Owns the channel store and contributes the channel tools. The
/// application assembly supplies the opener (workspace sqlite natively,
/// an injected implementation under wasm); the plugin opens at session
/// start, joins `#lobby` so the workspace sees the agent, and closes
/// with the session. Joining writes the member row and announces a
/// status message — presence from the first second of the session.
final class ChannelPlugin extends AgentPlugin {
  ChannelPlugin({
    required this.openStore,
    required this.agentName,
    this.role = 'agent',
  });

  /// Opens the store this plugin owns.
  final ChannelStoreOpener openStore;

  /// The agent identity messages self-attribute with (`tina-main`,
  /// `perm-boxes-agent`, …).
  final String agentName;

  /// The presence role written with membership rows.
  final String role;

  ChannelStoreApi? _store;
  ChannelTools? _tools;

  /// The store the TUI pane may borrow (read-only by convention); null
  /// before the session opens. The pane must read through the
  /// interface and never close this store.
  ChannelStoreApi? get storeForUi => _store;

  @override
  String get id => 'tina/channel';

  @override
  List<ToolSchema> get tools => _tools?.tools ?? const [];

  @override
  SessionSeed? openSession(PluginSession session) {
    final store = openStore();
    try {
      store.setMember('#lobby', agentName,
          status: 'working', role: role, announce: true);
    } on Object {
      store.close();
      rethrow;
    }
    _store = store;
    _tools = ChannelTools(store: store, agentName: agentName, role: role);
    return null;
  }

  @override
  void mountOn(AgentLoop loop) => _tools?.mountOn(loop);

  @override
  void onPrompt(TurnContext context) => _tools?.onPrompt(context);

  @override
  void closeSession() {
    _tools = null;
    _store?.close();
    _store = null;
  }
}
