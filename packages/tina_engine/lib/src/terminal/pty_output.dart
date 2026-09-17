import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

/// One ordered consumer of PTY bytes. Credits are returned only on delivery,
/// never when bytes merely enter a paused subscription's private buffer.
/// The worker cannot read more than its credit window until this consumer runs.
class PtyOutput {
  final void Function(int bytes) onConsumed;
  final Queue<Uint8List> _pending = Queue();
  late final StreamController<Uint8List> _controller;
  int pendingBytes = 0;
  bool _finished = false;
  bool _scheduled = false;
  bool _cancelled = false;

  PtyOutput({required this.onConsumed}) {
    _controller = StreamController<Uint8List>(
      sync: true,
      onListen: _schedule,
      onResume: _schedule,
      onCancel: () {
        // Cancellation explicitly abandons this consumer. Continue returning
        // credits so disposal cannot strand the child on a full PTY.
        _cancelled = true;
        final bytes = pendingBytes;
        _pending.clear();
        pendingBytes = 0;
        if (bytes != 0) onConsumed(bytes);
      },
    );
  }

  Stream<Uint8List> get stream => _controller.stream;

  void add(Uint8List bytes) {
    if (_finished) throw StateError('output after PTY finalization');
    if (_cancelled) {
      onConsumed(bytes.length);
      return;
    }
    _pending.add(bytes);
    pendingBytes += bytes.length;
    _schedule();
  }

  void addError(Object error) => _controller.addError(error);

  void finish() {
    _finished = true;
    _schedule();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      if (!_controller.hasListener || _controller.isPaused || _cancelled)
        return;
      while (_pending.isNotEmpty && !_controller.isPaused && !_cancelled) {
        final chunk = _pending.removeFirst();
        pendingBytes -= chunk.length;
        _controller.add(chunk);
        onConsumed(chunk.length);
      }
      if (_finished && _pending.isEmpty && !_controller.isClosed) {
        unawaited(_controller.close());
      }
    });
  }
}
