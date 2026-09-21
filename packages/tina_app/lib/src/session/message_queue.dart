import 'dart:collection';

class MessageQueue {
  final Queue<({String text, bool route})> _queue = Queue();

  void enqueue(String message, {bool route = true}) {
    final trimmed = message.trim();
    if (trimmed.isNotEmpty) _queue.addLast((text: trimmed, route: route));
  }

  String? dequeue() => take()?.text;

  /// Preserve whether queued work is user input or an internal follow-up.
  ({String text, bool route})? take() {
    if (_queue.isEmpty) return null;
    return _queue.removeFirst();
  }

  bool get isNotEmpty => _queue.isNotEmpty;
  bool get isEmpty => _queue.isEmpty;
  int get length => _queue.length;
  void clear() => _queue.clear();
}
