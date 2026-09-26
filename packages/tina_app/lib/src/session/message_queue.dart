import 'package:tina_engine/invocation.dart' as engine show Invocation;
import 'dart:collection';
import '../execution/input_routes.dart';

typedef QueuedInput = ({
  String text,
  bool route,
  PreparedInput? prepared,
  engine.Invocation? invocation,
});

class MessageQueue {
  final Queue<QueuedInput> _queue = Queue();

  void enqueue(
    String message, {
    bool route = true,
    PreparedInput? prepared,
    engine.Invocation? invocation,
  }) {
    final trimmed = message.trim();
    if (trimmed.isNotEmpty)
      _queue.addLast((
        text: trimmed,
        route: route,
        prepared: prepared,
        invocation: invocation,
      ));
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

  /// A snapshot of the queued inputs, first (next to run) last. Callers that
  /// are about to [clear] the queue use this to settle what they discard.
  List<QueuedInput> toList() => List.of(_queue);

  void clear() {
    for (final input in _queue) {
      input.prepared?.cancel();
      input.invocation?.cancel('Queued input cleared');
    }
    _queue.clear();
  }
}
