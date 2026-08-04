import 'dart:async';

import '../input_event.dart';
import '../input_parser.dart';
import '../stdio.dart';
import 'input_backend.dart';
import '../input_latency.dart';

/// Input backend that reads raw bytes from [Stdio.stdin] and parses them
/// into [InputEvent]s via [InputParser].
///
/// [InputParser] is a synchronous state machine: [InputParser.feed] returns
/// an [InputEvent] immediately, and the escape timeout delivers events via
/// a callback. This adapter wires both paths into a single [events] stream.
class AnsiInputBackend implements InputBackend {
  final Stdio _io;
  late final StreamController<InputEvent> _controller;
  late final InputParser _parser;
  StreamSubscription<List<int>>? _sub;
  bool _disposed = false;

  AnsiInputBackend({
    required Stdio io,
    bool macosOptionAsMeta = false,
    Duration escapeTimeout = const Duration(milliseconds: 150),
  }) : _io = io {
    _parser = InputParser(
      escapeTimeout: escapeTimeout,
      onTimeout: _emit,
      macosOptionAsMeta: macosOptionAsMeta,
    );
    // Lazy-subscribe so simply constructing a backend doesn't consume the
    // shared stdin stream — important for tests that build multiple editors.
    _controller = StreamController<InputEvent>(
      sync: true,
      onListen: () {
        if (_disposed) return;
        _sub ??= _io.stdin.listen(_onBytes);
      },
      onCancel: () {
        _sub?.cancel();
        _sub = null;
      },
    );
  }

  @override
  Stream<InputEvent> get events => _controller.stream;

  @override
  Future<void> get ready => Future<void>.value();

  /// Feed raw bytes directly, as if they came from stdin.
  /// Used for programmatic input injection (e.g. signal handlers).
  void feedBytes(List<int> bytes) => _onBytes(bytes);

  @override
  void inject(InputEvent event) => _emit(event);

  void _onBytes(List<int> bytes) {
    // Emit the first event synchronously, then defer subsequent events from
    // the same stdio chunk to the microtask queue. Without this, a paste
    // (which arrives as one large chunk of ASCII bytes) fires N+1 CharInput
    // events synchronously inside this loop; only the first event reaches
    // the readKey completer before _keyCompleter is reset, and the rest are
    // silently dropped into _dispatchEvent / the instruction buffer.
    var first = true;
    for (final b in bytes) {
      final event = _parser.feed(b);
      if (event != null) {
        if (first) {
          first = false;
          _emit(event);
        } else {
          scheduleMicrotask(() => _emit(event));
        }
      }
    }
  }

  void _emit(InputEvent event) {
    InputLatency.beginIfAbsent(event);
    if (!_controller.isClosed) {
      _controller.add(event);
    }
  }

  /// Stop listening for input.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sub?.cancel();
    _sub = null;
    _parser.dispose();
    _controller.close();
  }
}
