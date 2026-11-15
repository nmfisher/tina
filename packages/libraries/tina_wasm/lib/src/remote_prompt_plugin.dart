/// An opt-in Tina AgentPlugin adapter backed by the host's per-plugin Store.
library;

import 'package:tina_core/tina_core.dart' show PluginSession;
import 'package:tina_engine_2/tina_engine_2.dart'
    show AgentPlugin, SessionSeed, TurnContext;

import 'plugin_manager.dart';
import 'prompt_bridge_types.dart';

export 'prompt_bridge_types.dart';

final class RemotePromptPlugin extends AgentPlugin {
  /// Pass an explicit [manager] to share the lease book with a
  /// [WasmPluginAdminPlugin]; the manager is the single writer, this plugin
  /// derives its lease from it.
  RemotePromptPlugin(this._host, {PluginManager? manager})
    : _manager = manager ?? PluginManager(bridge: _host);

  static const pluginId = wasmPromptPluginId;

  final PromptPluginHostBridge _host;
  final PluginManager _manager;
  PluginSession? _session;

  @override
  String get id => pluginId;

  @override
  SessionSeed? openSession(PluginSession session) {
    if (_manager.isOpen) {
      throw StateError('Wasm prompt plugin is already open');
    }
    switch (_manager.open()) {
      case PromptBridgeOk():
        _session = session;
        return null;
      case PromptBridgeError():
        throw StateError('Wasm prompt plugin open failed');
    }
  }

  @override
  Future<void> onPrompt(TurnContext context) async {
    final session = _session;
    final lease = _manager.lease;
    if (session == null || lease == null) {
      throw StateError('Wasm prompt plugin is not open');
    }
    final lifecycle = _manager.status().lifecycle;
    final result = await _host.onPrompt(
      lease: lease,
      sessionId: session.id,
      model: session.model ?? '',
    );
    if (context.cancelled) return;
    if (_manager.lease != lease ||
        _manager.status().lifecycle != lifecycle) {
      throw StateError('Wasm prompt plugin retired during onPrompt');
    }
    switch (result) {
      case PromptBridgeOk(value: final section):
        if (section.isNotEmpty) context.promptSections.add(section);
      case PromptBridgeError():
        throw StateError('Wasm prompt plugin onPrompt failed');
    }
  }

  @override
  void closeSession() {
    _session = null;
    if (_manager.lease == null) return;
    switch (_manager.close()) {
      case PromptBridgeOk():
        return;
      case PromptBridgeError():
        throw StateError('Wasm prompt plugin close failed');
    }
  }
}
