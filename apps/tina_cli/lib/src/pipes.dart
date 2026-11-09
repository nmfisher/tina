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
/// * `{"op":"approve","id":"...","decision":"allow"}` — answer a pending
///   approval request (`allow`, `always` or `deny`); the reply's
///   `accepted` is false when no such request is pending.
/// * `{"op":"status"}` — emit the current status immediately.
/// * `{"op":"commands"}` — re-emit the command vocabulary (also carried in
///   `ready`): `[{name,description,allowWhileRunning,inputPrefix}]`.
/// * `{"op":"settings"}` — emit the settings catalog the engine serves:
///   public definitions (id, label, kind, scopes, choices, default) plus
///   each setting's resolved value and scope, secrets masked.
/// * `{"op":"history","afterSeq":N,"limit":M}` — page committed log
///   entries through the live snapshot, as a front end would.
/// * `{"op":"notices","afterSeq":N,"limit":M}` — page notices explicitly.
/// * `{"op":"complete","name":"/mode","prefix":"a"}` — command completion.
/// * `{"op":"operation","plugin":"tina/mode","operation":"set",
///    "arguments":{...},"id":"mode-1"}` — invoke a plugin operation under
///   a caller-chosen request ID; receipts report its lifecycle like a
///   submitted turn's.
/// * `{"op":"answer","id":"q1","text":"..."}` — answer a pending question
///   (`accepted` is false when none is pending).
/// * `{"op":"dismiss","id":"q1"}` — dismiss a pending question.
/// * `{"op":"shutdown"}` — stop cleanly; the process exits 0.
///
/// Events: `ready` (carries `commands`), `snapshot` (one per update: the
/// feature projections the TUI consumes — live chat previews, plugin
/// state — plus active tools, pending questions, the plugin list and the
/// notice watermark), `status`, `receipt`, `entry` (one per committed log
/// entry, JSON exactly as the session log serializes it), `notice` (and a
/// `notices-expired` marker when records have aged out), `cancel`,
/// `approval` (a request awaiting an answer), `approval-result` (the
/// answer's outcome), `question-result`, `history-page`, `notice-page`,
/// `suggestions`, `settings`, `overflow` (queued events dropped under
/// load, with the count), `error`, `bye`. Stdin EOF behaves like
/// `shutdown`.
///
/// This file lives in the application package, outside the engine
/// packages: `dart:io` belongs here and nowhere near the engine.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'pipes_stdio.dart';

import 'package:tina_approvals/tina_approvals.dart'
    show ApprovalDecision, ApprovalRequest, StreamApprovalChannel;
import 'package:tina_host/tina_host.dart';
import 'package:tina_settings/tina_settings.dart' show SettingDefinition;

import 'assembly.dart';

/// Line-decodes [source] without the stream-transformer chain: under
/// dart2wasm the typed-transformer covariance check rejects
/// `utf8.decoder` on a `Stream<Uint8List>`, and the protocol's needs are
/// one decoder and one splitter anyway. The split runs on raw bytes: a
/// line feed cannot occur inside a multi-byte sequence, so decoding only
/// whole lines never splits a character at a chunk boundary. (The old
/// per-chunk `utf8.decode` threw — killing the session — whenever the
/// writer's chunk edge fell inside a character.)
Stream<String> _linesOf(Stream<List<int>> source) async* {
  var carry = <int>[];
  await for (final chunk in source) {
    carry.addAll(chunk);
    var start = 0;
    for (var i = 0; i < carry.length; i++) {
      if (carry[i] != 0x0a) continue;
      yield utf8.decode(carry.sublist(start, i));
      start = i + 1;
    }
    if (start > 0) carry = carry.sublist(start);
  }
  if (carry.isNotEmpty) yield utf8.decode(carry);
}

/// Drives [assembly] over pipes until `shutdown`, stdin EOF or SIGINT.
/// Returns the process exit code. The caller owns assembly shutdown.
/// [maxQueuedEvents]/[maxQueuedCharacters] bound the outbound queue; the
/// defaults are the production bounds.
Future<int> runSessionPipes(
  SessionAssembly assembly, {
  Stream<List<int>>? input,
  void Function(String line)? emit,
  int maxQueuedEvents = _SessionPipes.defaultMaxQueuedEvents,
  int maxQueuedCharacters = _SessionPipes.defaultMaxQueuedCharacters,
}) async {
  final pipes = _SessionPipes(
    assembly,
    input: input,
    emit: emit ?? defaultPipesEmit,
    maxQueuedEvents: maxQueuedEvents,
    maxQueuedCharacters: maxQueuedCharacters,
  );
  try {
    return await pipes.run();
  } finally {
    pipes.release();
  }
}

final class _SessionPipes {
  static const defaultMaxQueuedEvents = 1024;
  static const defaultMaxQueuedCharacters = 8 << 20;

  _SessionPipes(
    this.assembly, {
    required this.input,
    required void Function(String line) emit,
    this.maxQueuedEvents = defaultMaxQueuedEvents,
    this.maxQueuedCharacters = defaultMaxQueuedCharacters,
  }) : _emit = emit;

  final SessionAssembly assembly;
  final Stream<List<int>>? input;
  final void Function(String line) _emit;

  /// Outbound bounds. A consumer that stops reading must not grow the
  /// queue without end: the oldest queued events are dropped, and one
  /// `overflow` event carrying the dropped count is written once the
  /// queue drains. Entries and notices are recoverable through the
  /// `history`/`notices` ops; receipts and status are re-derived from
  /// the session, and the immediate-write path never queues at all.
  final int maxQueuedEvents, maxQueuedCharacters;
  late final SessionConnection connection = assembly.host.connect();
  late final SessionAttachment attachment = connection.attach();
  final _requests = <String, SessionRequest>{};
  final _receiptStates = <String, SessionRequestState>{};
  final _outbound = Queue<String>();
  var _outboundCharacters = 0;
  var _dropped = 0;
  bool _flushScheduled = false;
  bool _done = false;
  StreamSubscription<String>? _reader;
  StreamSubscription<void>? _signals;

  Future<int> run() async {
    _emitNow(_readyEvent());
    unawaited(_observe());
    _observeApprovals();
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
    unawaited(_approvalRequests?.cancel());
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
  /// The queue is bounded ([maxQueuedEvents], [maxQueuedCharacters]); when
  /// full, the oldest queued events drop and the drop is reported.
  void _queue(Object event) {
    final encoded = jsonEncode(event);
    while (_outbound.isNotEmpty &&
        (_outbound.length >= maxQueuedEvents ||
            _outboundCharacters + encoded.length > maxQueuedCharacters)) {
      _outboundCharacters -= _outbound.removeFirst().length;
      _dropped++;
    }
    _outbound.add(encoded);
    _outboundCharacters += encoded.length;
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
    if (_dropped > 0) {
      final dropped = _dropped;
      _dropped = 0;
      // Written directly, after the queue has drained: the marker sits
      // behind every event that survived, never interleaved with them.
      _emit(jsonEncode({'type': 'overflow', 'dropped': dropped}));
    }
  }

  // ---- observation -------------------------------------------------------

  /// Push committed log entries as they publish, through the same
  /// snapshot + history-page contract a front end uses. The cursor carries
  /// across snapshots, so each entry is emitted exactly once. The same
  /// snapshots carry what a front end reads beyond the log: feature
  /// projections, active tools, pending questions, the plugin list and
  /// the notice watermark (`snapshot`), and notices themselves (`notice`).
  Future<void> _observe() async {
    var snapshot = attachment.initial;
    var lastSeq = -1;
    try {
      while (!_done) {
        _live = snapshot;
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
        _queueNotices(snapshot);
        _queue(_snapshotEvent(snapshot));
        final update = await attachment.next();
        if (update == null) return;
        snapshot = update.snapshot;
      }
    } catch (error) {
      _queue({'type': 'error', 'error': 'observation stopped: $error'});
    }
  }

  /// Pages the notices a snapshot makes visible and queues them with their
  /// own sequence numbers; a detected expiry gap is reported once, with
  /// the history position the omission belongs to. The cursors persist
  /// across updates on the instance, so each notice is emitted once.
  void _queueNotices(SessionSnapshot snapshot) {
    var guard = 0;
    while (_lastNoticeSeq < snapshot.throughNoticeSeq && guard++ < 64) {
      final page = attachment.notices(
        snapshot: snapshot,
        afterSeq: _lastNoticeSeq,
        limit: 64,
      );
      if (page.entries.isEmpty) break;
      for (final notice in page.entries) {
        _queue({
          'type': 'notice',
          'seq': notice.seq,
          'afterHistorySeq': notice.afterHistorySeq,
          'text': notice.text,
          if (notice.truncated) 'truncated': true,
        });
        _lastNoticeSeq = notice.seq;
      }
      final gap = page.omittedThroughSeq;
      if (gap != null && gap > _expiredNoticeThrough) {
        _expiredNoticeThrough = gap;
        _queue({
          'type': 'notices-expired',
          'omittedThroughSeq': gap,
          if (page.omittedAfterHistorySeq case final afterHistory?)
            'omittedAfterHistorySeq': afterHistory,
        });
      }
    }
  }

  var _lastNoticeSeq = -1;

  /// The most recent snapshot the observation loop saw; the paging ops
  /// read through it so a page reflects the session now, not the attach
  /// time. Null before the loop's first pass.
  SessionSnapshot? _live;
  SessionSnapshot get _liveSnapshot => _live ?? attachment.initial;
  var _expiredNoticeThrough = -1;

  void _queueReceipts() {
    for (final entry in _requests.entries.toList()) {
      final snapshot = entry.value.snapshot;
      if (_receiptStates[entry.key] == snapshot.state) continue;
      _receiptStates[entry.key] = snapshot.state;
      _queue(_receiptEvent(entry.key, snapshot));
    }
  }

  // ---- approvals ----------------------------------------------------------

  /// The stream approval channel the assembly selected, when the plugin
  /// set carries one: every request it delivers is emitted as an
  /// `approval` event a pipes client answers with the `approve` op. A
  /// channel with no listener denies every delivery, so this subscription
  /// is what makes asks answerable at all on a headless engine.
  StreamApprovalChannel? _approvalChannel() {
    for (final plugin in assembly.host.plugins) {
      if (plugin is StreamApprovalChannel) return plugin;
    }
    return null;
  }

  void _observeApprovals() {
    final channel = _approvalChannel();
    if (channel == null) return;
    _approvals = channel;
    _approvalRequests = channel.requests.listen(
      (request) {
        _queue({
          'type': 'approval',
          'id': request.id,
          'operation': request.operation,
          'target': request.target,
          'reason': request.reason,
          'kind': request.kind.name,
        });
      },
      onError: (Object error) {
        _queue({'type': 'error', 'error': 'approval channel: $error'});
      },
    );
  }

  void _approve(Map<String, dynamic> request) {
    final channel = _approvals;
    if (channel == null) {
      throw StateError('no approval channel is attached');
    }
    final id = request['id'];
    final decisionName = request['decision'];
    if (id is! String || id.isEmpty) {
      throw ArgumentError('approve requires id');
    }
    final decision = switch (decisionName) {
      'allow' => ApprovalDecision.allow,
      'always' => ApprovalDecision.allowAlways,
      'deny' => ApprovalDecision.deny,
      _ => throw ArgumentError(
          'approve decision must be allow, always or deny'),
    };
    final accepted = channel.respond(id, decision);
    _emitNow({
      'type': 'approval-result',
      'id': id,
      'decision': decisionName,
      'accepted': accepted,
    });
  }

  StreamApprovalChannel? _approvals;
  StreamSubscription<ApprovalRequest>? _approvalRequests;

  // ---- wire encoding -----------------------------------------------------

  Map<String, Object?> _readyEvent() {
    final status = connection.status;
    return {
      'type': 'ready',
      'session': status.id,
      'model': status.model,
      'epoch': connection.requestWindow.epoch,
      'commands': [for (final c in connection.commands) _commandJson(c)],
    };
  }

  Map<String, Object?> _commandJson(SessionCommand c) => {
    'name': c.name,
    'description': c.description,
    'allowWhileRunning': c.allowWhileRunning,
    if (c.inputPrefix case final prefix?) 'inputPrefix': prefix,
  };

  /// The non-history snapshot surface a front end consumes: feature
  /// projections (live chat previews, plugin state), active tool progress,
  /// pending questions, the plugin list and the notice watermark. Values
  /// are the host's detached public data.
  Map<String, Object?> _snapshotEvent(SessionSnapshot snapshot) => {
    'type': 'snapshot',
    'revision': snapshot.cursor.revision,
    'epoch': snapshot.cursor.epoch,
    'features': snapshot.features,
    'unavailableFeatures': snapshot.unavailableFeatures,
    'activeTools': snapshot.activeTools,
    'questions': [
      for (final q in snapshot.questions)
        {
          'id': q.id,
          'prompt': q.prompt,
          if (q.expiresAt case final expires?) 'expiresAt': expires.toIso8601String(),
        },
    ],
    'plugins': snapshot.plugins,
    'pendingInputs': snapshot.pendingInputs.length,
    'throughNoticeSeq': snapshot.throughNoticeSeq,
  };

  /// The settings catalog the engine serves: public definitions plus each
  /// setting's resolved value and scope. Secrets never carry values.
  Map<String, Object?> _settingsEvent() {
    final catalog = assembly.settings.catalog;
    return {
      'type': 'settings',
      'model': connection.status.model,
      'plugins': [for (final p in assembly.host.plugins) p.id],
      'settings': [
        for (final definition in catalog.definitions) _settingJson(definition),
      ],
    };
  }

  Map<String, Object?> _settingJson(SettingDefinition<Object> definition) {
    Object? value;
    String? source;
    var error = false;
    try {
      final resolved = assembly.settings.read<Object>(definition);
      value = resolved.value;
      source = resolved.source?.name;
    } catch (_) {
      error = true;
    }
    return {
      'id': definition.id,
      'owner': definition.owner,
      'label': definition.label,
      'description': definition.description,
      'kind': definition.kind.name,
      'scopes': [for (final s in definition.scopes) s.name],
      'applyAt': definition.applyAt.name,
      if (definition.secret) 'secret': true,
      if (definition.minimum case final min?) 'minimum': min,
      if (definition.maximum case final max?) 'maximum': max,
      if (definition.choices.isNotEmpty) 'choices': definition.choices,
      'default': definition.secret
          ? null
          : definition.encodeObject(definition.defaultValue),
      if (error) 'unreadable': true,
      if (!error && !definition.secret && value != null) ...{
        'value': definition.encodeObject(value),
        if (source case final source?) 'source': source,
      },
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
        case 'approve':
          _approve(decoded);
        case 'status':
          _emitNow(_statusEvent(connection.status));
          _queueReceipts();
        case 'commands':
          _emitNow({
            'type': 'commands',
            'commands': [for (final c in connection.commands) _commandJson(c)],
          });
        case 'settings':
          _queue(_settingsEvent());
        case 'history':
          _history(decoded);
        case 'notices':
          _noticePage(decoded);
        case 'complete':
          _complete(decoded);
        case 'operation':
          _operation(decoded);
        case 'answer':
          _answer(decoded);
        case 'dismiss':
          _dismiss(decoded);
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

  // ---- discovery and paging ops -------------------------------------------

  /// Pages committed entries through the live snapshot, exactly what the
  /// observation loop pushes — so a client that received an overflow
  /// marker (or joined late) can catch up from any sequence position.
  void _history(Map<String, dynamic> request) {
    final snapshot = _liveSnapshot;
    final afterSeq = _pageArg(request['afterSeq'], -1);
    final limit = _pageArg(request['limit'], 128);
    final page = connection.history(
        snapshot: snapshot, afterSeq: afterSeq, limit: limit);
    _queue({
      'type': 'history-page',
      'afterSeq': afterSeq,
      'nextAfterSeq': page.nextAfterSeq,
      'hasMore': page.hasMore,
      'entries': [
        for (final entry in page.entries)
          freezeSnapshotValue(entry) as Map<String, Object?>,
      ],
    });
  }

  /// Pages notices explicitly; the same records the observation loop
  /// pushes as `notice` events.
  void _noticePage(Map<String, dynamic> request) {
    final snapshot = _liveSnapshot;
    final afterSeq = _pageArg(request['afterSeq'], -1);
    final limit = _pageArg(request['limit'], 128);
    final page = connection.notices(
        snapshot: snapshot, afterSeq: afterSeq, limit: limit);
    _queue({
      'type': 'notice-page',
      'afterSeq': afterSeq,
      'nextAfterSeq': page.nextAfterSeq,
      'hasMore': page.hasMore,
      'entries': [
        for (final n in page.entries)
          {
            'seq': n.seq,
            'afterHistorySeq': n.afterHistorySeq,
            'text': n.text,
            if (n.truncated) 'truncated': true,
          },
      ],
    });
  }

  void _complete(Map<String, dynamic> request) {
    final name = request['name'];
    if (name is! String || name.isEmpty) {
      throw ArgumentError('complete requires name');
    }
    final prefix = request['prefix'];
    unawaited(connection
        .completeCommand(name, prefix is String ? prefix : '')
        .then((suggestions) {
      if (_done) return;
      _emitNow({
        'type': 'suggestions',
        'name': name,
        'suggestions': suggestions,
      });
    }, onError: (Object error) {
      if (_done) return;
      _emitNow({'type': 'error', 'error': 'complete: $error', 'op': 'complete'});
    }));
  }

  /// A plugin operation under a caller-chosen request ID; its lifecycle
  /// rides the same receipts a submitted turn's does.
  void _operation(Map<String, dynamic> request) {
    final plugin = request['plugin'];
    final operation = request['operation'];
    final id = request['id'];
    final arguments = request['arguments'];
    if (plugin is! String ||
        plugin.isEmpty ||
        operation is! String ||
        operation.isEmpty) {
      throw ArgumentError('operation requires plugin and operation');
    }
    if (id is! String || id.isEmpty || id.length > 128) {
      throw ArgumentError('operation requires id (1-128 chars)');
    }
    if (arguments != null && arguments is! Map<String, dynamic>) {
      throw ArgumentError('operation arguments must be an object');
    }
    final requestId = connection.requestWindow.id(id);
    final record = connection.submitOperation(
      plugin,
      operation,
      arguments: arguments is Map<String, dynamic> ? arguments : const {},
      id: requestId,
    );
    _requests[id] = record;
    _receiptStates[id] = record.snapshot.state;
    _emitNow(_receiptEvent(id, record.snapshot));
  }

  void _answer(Map<String, dynamic> request) {
    final id = request['id'];
    final text = request['text'];
    if (id is! String || id.isEmpty) {
      throw ArgumentError('answer requires id');
    }
    final accepted =
        connection.questions.answer(id, text is String ? text : '');
    _emitNow({'type': 'question-result', 'id': id, 'accepted': accepted});
  }

  void _dismiss(Map<String, dynamic> request) {
    final id = request['id'];
    if (id is! String || id.isEmpty) {
      throw ArgumentError('dismiss requires id');
    }
    final accepted = connection.questions.dismiss(id);
    _emitNow({'type': 'question-result', 'id': id, 'accepted': accepted});
  }

  int _pageArg(Object? raw, int fallback) =>
      raw is num ? raw.toInt() : fallback;
}
