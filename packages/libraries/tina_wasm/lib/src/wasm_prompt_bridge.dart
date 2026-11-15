/// Adapt the generated component-model imports to the engine's pure Dart seam.
library;

import 'package:wasm_components/wasm_components.dart' as cm;

import 'components/tina_plugin_host.dart' as host_wit;
import 'remote_prompt_plugin.dart';

final class WasmPromptPluginHostBridge implements PromptPluginHostBridge {
  const WasmPromptPluginHostBridge(this._host);

  final host_wit.Session _host;

  @override
  PromptBridgeResult<String> open() => _map(_host.open());

  @override
  Future<PromptBridgeResult<String>> onPrompt({
    required String lease,
    required String sessionId,
    required String model,
  }) async => _map(
    await _host.onPrompt(lease: lease, sessionId: sessionId, model: model),
  );

  @override
  PromptBridgeResult<void> close({required String lease}) =>
      _map(_host.close(lease: lease));

  PromptBridgeResult<T> _map<T>(cm.Result<T, host_wit.SessionError> result) =>
      switch (result) {
        cm.OkResult(value: final value) => PromptBridgeResult<T>.ok(value),
        cm.ErrorResult(value: final error) => PromptBridgeResult<T>.error(
          switch (error) {
            host_wit.SessionErrorDenied() => PromptBridgeFailure.denied,
            host_wit.SessionErrorUnavailable() =>
              PromptBridgeFailure.unavailable,
            host_wit.SessionErrorFailed() => PromptBridgeFailure.failed,
          },
        ),
      };
}
