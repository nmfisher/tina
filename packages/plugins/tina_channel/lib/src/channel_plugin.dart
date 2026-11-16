import 'dart:math';

import 'package:tina_engine_2/tina_engine_2.dart';

import '../channel_store_api.dart';
import 'channel_tools.dart';
import 'shortcode.dart';

/// Owns the channel store and contributes the channel tools. The
/// application assembly supplies the opener (workspace sqlite natively,
/// an injected implementation under wasm); the plugin opens at session
/// start, settles the agent identity, joins `#lobby` so the workspace
/// sees the agent, and closes with the session. Joining writes the
/// member row and announces a status message — presence from the first
/// second of the session.
///
/// Identity: [agentName] is the explicit override (used verbatim);
/// null — the assembly default — generates a shortcode
/// (`calm-heron`) once per session, collision-checked against the
/// store's active members. The role (main/subagent/task label) rides
/// the members table, never the name. The identity is decided here at
/// the composition seam, never inside the tools.
final class ChannelPlugin extends AgentPlugin {
  ChannelPlugin({
    required this.openStore,
    this.agentName,
    this.role = 'agent',
    this.random,
  });

  /// Opens the store this plugin owns.
  final ChannelStoreOpener openStore;

  /// The agent identity messages self-attribute with: an explicit
  /// override, or null to generate a per-session shortcode.
  final String? agentName;

  /// The presence role written with membership rows (`main`, `agent`,
  /// task label).
  final String role;

  /// The randomness source for shortcode generation (tests inject a
  /// scripted one; sessions pass nothing).
  final Random? random;

  ChannelStoreApi? _store;
  ChannelTools? _tools;
  String? _effectiveName;

  /// The settled identity once the session has opened (the override
  /// verbatim, or the generated shortcode); null before.
  String? get name => _effectiveName;

  /// The store a UI may borrow for reads; null before the session
  /// opens. A borrower reads through the interface and never closes
  /// this store.
  ChannelStoreApi? get storeForUi => _store;

  @override
  String get id => 'tina/channel';

  @override
  List<ToolSchema> get tools => _tools?.tools ?? const [];

  @override
  SessionSeed? openSession(PluginSession session) {
    final store = openStore();
    final String identity;
    try {
      identity = agentName ?? settleAgentName(store, random);
      store.setMember('#lobby', identity,
          status: 'working', role: role, announce: true);
    } on Object {
      store.close();
      rethrow;
    }
    _store = store;
    _effectiveName = identity;
    _tools =
        ChannelTools(store: store, agentName: identity, role: role);
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
    _effectiveName = null;
  }
}
