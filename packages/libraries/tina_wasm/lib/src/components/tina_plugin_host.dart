// ignore_for_file: type=warning
import r'package:wasm_components/wasm_components.dart' as i0;

sealed class SessionError {
  const SessionError._();
  const factory SessionError.denied() = SessionErrorDenied;
  const factory SessionError.unavailable() = SessionErrorUnavailable;
  const factory SessionError.failed() = SessionErrorFailed;
}

final class SessionErrorDenied extends SessionError {
  const SessionErrorDenied() : super._();
}

final class SessionErrorUnavailable extends SessionError {
  const SessionErrorUnavailable() : super._();
}

final class SessionErrorFailed extends SessionError {
  const SessionErrorFailed() : super._();
}

/// Host-mediated lifecycle for one configured guest AgentPlugin. The lease is
/// issued by the host on open and is scoped to that plugin Store instance.
abstract interface class Session {
  i0.Result<String, SessionError> open();

  /// Invoke the configured plugin against immutable session context. The host
  /// must not re-enter the suspended Tina engine Store while handling this call.
  Future<i0.Result<String, SessionError>> onPrompt({
    required String lease,
    required String sessionId,
    required String model,
  });

  /// Revoke the lease and retire only its plugin Store.
  i0.Result<void, SessionError> close({required String lease});
}
