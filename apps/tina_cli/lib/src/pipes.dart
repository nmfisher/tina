/// Headless pipe protocol for one assembled session.
///
/// The engine side of stage-1 wasm verification: the session is driven over
/// plain pipes instead of a terminal. Requests are line-delimited JSON
/// objects on stdin; events are line-delimited JSON objects on stdout.
/// Nothing here designs a framework — every message is the thinnest
/// serialization of the in-process front-end contract (`SessionConnection`,
/// `SessionAttachment`) that an external client needs:
///
/// * `{"op":"submit","id":"c1","line":"..."}` — submit input (or a command)
///   under a caller-chosen request ID; a retry with the same ID and text
///   returns the same receipt.
/// * `{"op":"cancel","work":"work-2","reason":"..."}` — cancel one active
///   work ID (a stale ID is reported, never applied to a successor).
/// * `{"op":"status"}` — emit the current status immediately.
/// * `{"op":"shutdown"}` — stop cleanly; the process exits 0.
///
/// Events: `ready`, `status`, `receipt`, `entry` (one per committed log
/// entry, JSON exactly as the session log serializes it), `cancel`,
/// `error`, `bye`. Stdin EOF behaves like `shutdown`.
///
/// This file lives in the application package, outside the engine
/// packages: `dart:io` belongs here and nowhere near the engine.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'pipes_stdio.dart';

import 'package:tina_host/tina_host.dart';

import 'assembly.dart';

/// Line-decodes [source] without the stream-transformer chain: under
/// dart2wasm the typed-transformer covariance check rejects
/// `utf8.decoder` on a `Stream<Uint8List>`, and the protocol's needs are
/// one decoder and one splitter anyway.
Stream<String> _linesOf(Stream<List<int>> source) async* {
  var carried = '';
  await for (final chunk in source) {
    carried = '$carried${utf8.decode(chunk)}';
    int newline;
    while ((newline = carried.indexOf('\n')) >= 0) {
      yield carried.substring(0, newline);
      carried = carried.substring(newline + 1);
    }
  }
  if (carried.isNotEmpty) yield carried;
}

/// Drives [assembly] over pipes until `shutdown`, stdin EOF or SIGINT.
/// Returns the process exit code. The caller owns assembly shutdown.
Future<int> runSessionPipes(
  SessionAssembly assembly, {
  Stream<List<int>>? input,
  void Function(String line)? emit,
}) async {
  final pipes = _SessionPipes(
    assembly,
    input: input,
    emit: emit ?? defaultPipesEmit,
  );
  try {
    return await pipes.run();
  } finally {
    pipes.release();
  }
}

final class _SessionPipes {
  _SessionPipes(
    this.assembly, {
    required this.input,
    required void Function(String line) emit,
  }) : _emit = emit;

  final SessionAssembly assembly;
  final Stream<List<int>>? input;
  final void Function(String line) _emit;

  late final SessionConnection connection = assembly.host.connect();
  late final SessionAttachment attachment = connection.attach();
  final _requests = <String, SessionRequest>{};
  final _receiptStates = <String, SessionRequestState>{};
  final _outbound = Queue<String>();
  bool _flushScheduled = false;
  bool _done = false;
  StreamSubscription<String>? _reader;
  StreamSubscription<void>? _signals;

  Future<int> run() async {
    _emitNow(_readyEvent());
    unawaited(_observe());
    final stop = Completer<int>();
    final interrupt = canWatchInterrupt
        ? interruptStream().listen((_) {
            if (!_done) {
              _queue({'type': 'bye', 'reason': 'interrupt'});
              _finish(stop, 130);
            }
          })
        : null;
    _signals = interrupt;
    connection.listen((status) {
      if (_done) return;
      _queue(_statusEvent(status));
      _queueReceipts();
    });
    // A null default means this platform supplies no stdin: the session
    // ends immediately, exactly as stdin EOF does.
    final source = input ?? defaultPipesInput();
    final lines = source == null
        ? const Stream<String>.empty()
        : _linesOf(source);
    final subscription = lines.listen(
      (line) {
        _handleLine(line, stop);
      },
      onDone: () {
        if (!_done) {
          _queue(const {'type': 'bye', 'reason': 'eof'});
          _finish(stop, 0);
        }
      },
    );
    _reader = subscription;
    try {
      return await stop.future;
    } finally {
      await _flush();
    }
  }

  void _finish(Completer<int> stop, int code) {
    if (_done) return;
    _done = true;
    unawaited(_reader?.cancel());
    if (_signals != null) unawaited(_signals!.cancel());
    stop.complete(code);
  }

  Future<void> release() async {
    attachment.close();
    connection.close();
  }

  // ---- outbound delivery -------------------------------------------------

  /// Events are queued and written from the event loop, never from inside a
  /// host listener callback: a slow pipe consumer cannot poison the loop.
  void _queue(Object event) {
    _outbound.add(jsonEncode(event));
    _scheduleFlush();
  }

  /// A response the client is blocked on is written immediately; the reader
  /// loop is engine-free, so writing here cannot stall a turn.
  void _emitNow(Object event) => _emit(jsonEncode(event));

  void _scheduleFlush() {
    if (_flushScheduled) return;
    _flushScheduled = true;
    scheduleMicrotask(() {
      _flushScheduled = false;
      unawaited(_flush());
    });
  }

  Future<void> _flush() async {
    while (_outbound.isNotEmpty) {
      _emit(_outbound.removeFirst());
    }
  }

  // ---- observation -------------------------------------------------------

  /// Push committed log entries as they publish, through the same
  /// snapshot + history-page contract a front end uses. The cursor carries
  /// across snapshots, so each entry is emitted exactly once.
  Future<void> _observe() async {
    var snapshot = attachment.initial;
    var lastSeq = -1;
    try {
      while (!_done) {
        if (snapshot.historyPublicationFailed) {
          _queue(const {
            'type': 'error',
            'error': 'history publication failed; entries may be missing',
          });
        }
        while (lastSeq < snapshot.throughSeq) {
          final page = attachment.history(
            snapshot: snapshot,
            afterSeq: lastSeq,
            limit: 128,
          );
          if (page.entries.isEmpty) break;
          for (final entry in page.entries) {
            lastSeq = (entry['seq'] as num).toInt();
            _queue({'type': 'entry', 'seq': lastSeq, 'entry': entry});
          }
        }
        final update = await attachment.next();
        if (update == null) return;
        snapshot = update.snapshot;
      }
    } catch (error) {
      _queue({'type': 'error', 'error': 'observation stopped: $error'});
    }
  }

  void _queueReceipts() {
    for (final entry in _requests.entries.toList()) {
      final snapshot = entry.value.snapshot;
      if (_receiptStates[entry.key] == snapshot.state) continue;
      _receiptStates[entry.key] = snapshot.state;
      _queue(_receiptEvent(entry.key, snapshot));
    }
  }

  // ---- wire encoding -----------------------------------------------------

  Map<String, Object?> _readyEvent() {
    final status = connection.status;
    return {
      'type': 'ready',
      'session': status.id,
      'model': status.model,
      'epoch': connection.requestWindow.epoch,
    };
  }

  Map<String, Object?> _statusEvent(SessionStatus status) => {
    'type': 'status',
    'running': status.running,
    'busy': status.busy,
    'stopping': status.stopping,
    'closed': status.closed,
    'acceptsInput': status.acceptsInput,
    'pendingInputCount': status.pendingInputCount,
    'work': [
      for (final work in status.cancellableWork)
        {'id': work.id, 'kind': work.kind},
    ],
  };

  Map<String, Object?> _receiptEvent(String id, SessionRequestSnapshot s) => {
    'type': 'receipt',
    'id': id,
    'state': s.state.name,
    if (s.inputId case final input?) 'inputId': input,
    if (s.workId case final work?) 'workId': work,
    if (s.result?.stopReason case final reason?) 'stopReason': reason.name,
    if (s.result?.detail case final detail? when detail.isNotEmpty)
      'detail': detail,
    if (s.resultTruncated) 'resultTruncated': true,
  };

  // ---- inbound handling --------------------------------------------------

  void _handleLine(String line, Completer<int> stop) {
    if (_done) return;
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      _emitNow(const {
        'type': 'error',
        'error': 'request is not a JSON object',
      });
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      _emitNow(const {
        'type': 'error',
        'error': 'request is not a JSON object',
      });
      return;
    }
    final op = decoded['op'];
    try {
      switch (op) {
        case 'submit':
          _submit(decoded);
        case 'cancel':
          _cancel(decoded);
        case 'status':
          _emitNow(_statusEvent(connection.status));
          _queueReceipts();
        case 'shutdown':
          _queue(const {'type': 'bye'});
          _finish(stop, 0);
        case null:
          _emitNow(const {'type': 'error', 'error': 'request has no op'});
        default:
          _emitNow({'type': 'error', 'error': 'unknown op: $op'});
      }
    } on StateError catch (error) {
      _emitNow({'type': 'error', 'error': error.message, 'op': '$op'});
    } on SessionRequestError catch (error) {
      _emitNow({'type': 'error', 'error': '$error', 'op': 'submit'});
    } on ArgumentError catch (error) {
      _emitNow({'type': 'error', 'error': '$error', 'op': '$op'});
    }
  }

  void _submit(Map<String, dynamic> request) {
    final id = request['id'];
    final text = request['line'];
    if (id is! String || id.isEmpty || id.length > 128 || text is! String) {
      throw ArgumentError('submit requires id (1-128 chars) and line');
    }
    final requestId = connection.requestWindow.id(id);
    final existing = _requests[id];
    final accepted = existing ?? connection.submitRequest(text, id: requestId);
    _requests[id] = accepted;
    _receiptStates[id] = accepted.snapshot.state;
    _emitNow(_receiptEvent(id, accepted.snapshot));
  }

  void _cancel(Map<String, dynamic> request) {
    final work = request['work'];
    if (work is! String || work.isEmpty) {
      throw ArgumentError('cancel requires work');
    }
    final reason = request['reason'];
    final accepted = connection.cancel([
      work,
    ], reason: reason is String && reason.isNotEmpty ? reason : 'client');
    _emitNow({'type': 'cancel', 'work': work, 'accepted': accepted});
  }
}
