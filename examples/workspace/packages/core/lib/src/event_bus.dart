/// A minimal synchronous pub/sub bus for [TaskEvent]s.
library;

import 'event.dart';

/// Signature of a subscriber callback. Return `false` to unsubscribe.
typedef TaskSubscriber = bool Function(TaskEvent event);

/// Fans events out to subscribers in registration order.
///
/// Re-entrant publishes (a subscriber publishing during dispatch) are
/// queued and dispatched after the current batch completes.
final class EventBus {
  final List<TaskSubscriber> _subscribers = [];
  final List<TaskEvent> _pending = [];
  bool _dispatching = false;

  /// Registers [subscriber]; returns a handle that cancels it.
  void Function() subscribe(TaskSubscriber subscriber) {
    _subscribers.add(subscriber);
    return () => _subscribers.remove(subscriber);
  }

  /// Publishes [event] to all current subscribers.
  void publish(TaskEvent event) {
    _pending.add(event);
    if (_dispatching) return;
    _dispatching = true;
    try {
      while (_pending.isNotEmpty) {
        final batch = List<TaskEvent>.of(_pending);
        _pending.clear();
        for (final event in batch) {
          // Iterate backwards so unsubscribing during dispatch is safe.
          for (var i = _subscribers.length - 1; i >= 0; i--) {
            if (!_subscribers[i](event)) {
              _subscribers.removeAt(i);
            }
          }
        }
      }
    } finally {
      _dispatching = false;
    }
  }

  /// Number of live subscribers — exposed for tests and metering.
  int get subscriberCount => _subscribers.length;
}
