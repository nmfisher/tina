import 'dart:collection';

class MessageQueue {
  final Queue<String> _queue = Queue<String>();

  void enqueue(String message) {
    final trimmed = message.trim();
    if (trimmed.isNotEmpty) _queue.addLast(trimmed);
  }

  String? dequeue() {
    if (_queue.isEmpty) return null;
    return _queue.removeFirst();
  }

  bool get isNotEmpty => _queue.isNotEmpty;
  bool get isEmpty => _queue.isEmpty;
  int get length => _queue.length;
  void clear() => _queue.clear();
}
