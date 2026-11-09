/// An opt-in Tina AgentPlugin adapter backed by the host's per-plugin Store.
library;

import 'package:tina_core/tina_core.dart' show PluginSession;
import 'package:tina_engine_2/tina_engine_2.dart'
    show AgentPlugin, SessionSeed, TurnContext;

/// Safe error classes returned by the imported host bridge.
enum PromptBridgeFailure { denied, unavailable, failed }

sealed class PromptBridgeResult<T> {
  const PromptBridgeResult();
  const factory PromptBridgeResult.ok(T value) = PromptBridgeOk<T>;
  const factory PromptBridgeResult.error(PromptBridgeFailure failure) =
      PromptBridgeError<T>;
}

final class PromptBridgeOk<T> extends PromptBridgeResult<T> {
  const PromptBridgeOk(this.value);
  final T value;
}

final class PromptBridgeError<T> extends PromptBridgeResult<T> {
  const PromptBridgeError(this.failure);
  final PromptBridgeFailure failure;
}

/// Pure Dart boundary used by the Tina engine. Native lifecycle tests can
/// supply a fake; the WASM composition root adapts generated WIT bindings.
abstract interface class PromptPluginHostBridge {
  PromptBridgeResult<String> open();
  Future<PromptBridgeResult<String>> onPrompt({
    required String lease,
    required String sessionId,
    required String model,
  });
  PromptBridgeResult<void> close({required String lease});
}

final class RemotePromptPlugin extends AgentPlugin {
  RemotePromptPlugin(this._host);

  static const pluginId = 'tina/wasm-prompt';

  final PromptPluginHostBridge _host;
  PluginSession? _session;
  String? _lease;
  var _lifecycle = 0;

  @override
  String get id => pluginId;

  @override
  SessionSeed? openSession(PluginSession session) {
    if (_lease != null) throw StateError('Wasm prompt plugin is already open');
    switch (_host.open()) {
      case PromptBridgeOk(value: final lease):
        _session = session;
        _lease = lease;
        _lifecycle++;
        return null;
      case PromptBridgeError():
        throw StateError('Wasm prompt plugin open failed');
    }
  }

  @override
  Future<void> onPrompt(TurnContext context) async {
    final session = _session;
    final lease = _lease;
    if (session == null || lease == null) {
      throw StateError('Wasm prompt plugin is not open');
    }
    final lifecycle = _lifecycle;
    final result = await _host.onPrompt(
      lease: lease,
      sessionId: session.id,
      model: session.model ?? '',
    );
    if (context.cancelled) return;
    if (_lease != lease || _lifecycle != lifecycle) {
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
    final lease = _lease;
    _lease = null;
    _session = null;
    _lifecycle++;
    if (lease == null) return;
    switch (_host.close(lease: lease)) {
      case PromptBridgeOk():
        return;
      case PromptBridgeError():
        throw StateError('Wasm prompt plugin close failed');
    }
  }
}
