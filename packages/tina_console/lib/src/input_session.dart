import 'input_event.dart';

/// Keyboard ownership for one complete dialog, including between key reads.
/// Events stay in this session's queue until read or explicitly discarded.
abstract interface class InputSession {
  /// Read the next ordered key. Cancellation or disposal returns Ctrl+C.
  /// A cancel signal settles reads; the owner must still dispose in finally.
  Future<InputEvent> read();
  Future<void> get closed;
  bool get isClosed;

  /// Release ownership, discard unread answer keys and settle pending reads.
  /// Idempotent; a disposed session can never consume another dialog's keys.
  void dispose();
}
