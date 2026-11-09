/// Pure Dart bridge types shared by the host adapter, the lease manager and
/// the admin command plugin. Safe error classes returned by the imported
/// host bridge; `PromptPluginHostBridge` is the boundary the Tina engine
/// codes against — native lifecycle tests can supply a fake, and the WASM
/// composition root adapts generated WIT bindings.
library;

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

abstract interface class PromptPluginHostBridge {
  PromptBridgeResult<String> open();
  Future<PromptBridgeResult<String>> onPrompt({
    required String lease,
    required String sessionId,
    required String model,
  });
  PromptBridgeResult<void> close({required String lease});
}

/// The composition root's only configured guest plugin today; the lease
/// manager and the admin command default to it.
const wasmPromptPluginId = 'tina/wasm-prompt';
