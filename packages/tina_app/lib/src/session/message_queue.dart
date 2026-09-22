import 'dart:collection';
import '../execution/input_routes.dart';

typedef QueuedInput = ({String text, bool route, PreparedInput? prepared});

class MessageQueue {
  final Queue<QueuedInput> _queue = Queue();

  void enqueue(String message, {bool route = true, PreparedInput? prepared}) {
    final trimmed = message.trim();
    if (trimmed.isNotEmpty)
      _queue.addLast((text: trimmed, route: route, prepared: prepared));
  }

  String? dequeue() => take()?.text;

  /// Preserve whether queued work is user input or an internal follow-up.
  QueuedInput? take() {
    if (_queue.isEmpty) return null;
    return _queue.removeFirst();
  }

  bool get isNotEmpty => _queue.isNotEmpty;
  bool get isEmpty => _queue.isEmpty;
  int get length => _queue.length;
  void clear() {
    for (final input in _queue) {
      input.prepared?.cancel();
    }
    _queue.clear();
  }
}
