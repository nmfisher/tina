/// A pipes-backed [SessionConnection]: the TUI's engine calls served over
/// the pipes protocol instead of an in-process host. The interface (in
/// `tina_host`) is the contract the front end codes against; this class
/// maps it onto the wire — status events, snapshot projections, receipts,
/// and the discovery ops — so no engine call requires an in-process
/// object.
///
/// Transport is injected: Phase B's launcher hands a spawned engine
/// process's stdio; tests hand stream controllers and drive the real
/// `runSessionPipes` on the other side, so the records here cover the
/// client contract end to end without a subprocess.
///
/// How the wire maps onto the interface:
/// - `status` events carry the liveness fields; `snapshot` events carry
///   the feature projections, active tools, questions, plugin list,
///   watermarks and pending inputs. The latest of each composes the
///   attachment's snapshot.
/// - Every pushed `entry` is cached locally, so `attach()` + `history()`
///   page synchronously over received data — the same pull contract the
///   in-process attachment serves. The `history` op remains the explicit
///   catch-up path (used when an overflow marker reports dropped entries).
/// - Receipts drive [PipesRequest]: submit/operation ops under
///   caller-chosen IDs, with `completed` resolving on the terminal state.
///
/// Deliberate divergences, all bounded by the protocol:
/// - `workingDirectory` is unknown over the wire and reads as ''.
/// - `inputHistory` reflects the entries this client has received, not
///   the whole session log (a `history` op page can extend the cache).
/// - `output`, `offerInput` and `offerCommand` have no remote semantics;
///   they throw [UnsupportedError]. Front ends drive `submitRequest`,
///   `submit` and `commandFor` instead.
/// - Attachment history skips the read-ahead RangeError: after an
///   overflow dropped pushed entries, paging forward past the local
///   watermark is exactly the recovery path.
/// - `cancel` reports whether the work appeared cancellable locally; the
///   engine's own accept/reply arrives as `cancel` events.
library;

import 'dart:async';

import 'package:tina_engine_2/tina_engine_2.dart' show Input, StopReason;
import 'package:tina_host/tina_host.dart';

/// The connection over the pipes protocol.
final class PipesConnection implements SessionConnection {
  /// [send] writes one protocol line (JSON-encoded here); [events] is the
  /// engine's decoded event stream. Query ops may be used once the
  /// [started] future completes.
  PipesConnection({
    required void Function(Object line) send,
    required Stream<Map<String, dynamic>> events,
  }) : _send = send {
    _subscription = events.listen(_onEvent, onDone: () {
      if (!_started.isCompleted) {
        _started.completeError(StateError('engine closed before ready'));
      }
      _closed = true;
      for (final request in _requests.values) {
        request._fail('engine closed');
      }
    });
  }

  final void Function(Object line) _send;
  late final StreamSubscription<Map<String, dynamic>> _subscription;

  final _started = Completer<void>();
  Future<void> get started => _started.future;

  bool _closed = false;
  String _epoch = '';
  String _model = '';
  final _requests = <String, PipesRequest>{};
  final _statusListeners = <Object, void Function(SessionStatus)>{};
  final _questionListeners = <Object, void Function(List<SessionQuestion>)>{};
  final _attachments = <_PipesAttachment>{};
  final _queries = <_QueryWaiter>{};
  final _entries = <Map<String, Object?>>[];
  final _notices = <SessionNotice>[];
  final _commands = <SessionCommand>[];
  int _throughSeq = -1;
  int _throughNoticeSeq = -1;
  SessionStatus _status = SessionStatus(
      id: '',
      model: '',
      workingDirectory: '',
      running: false,
      busy: false,
      acceptsInput: true,
      pendingInputCount: 0,
      stopping: false,
      closed: false,
      cancellableWork: const []);
  SessionSnapshot _snapshot = const _EmptySnapshot();

  void _onEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'ready':
        _epoch = event['epoch'] as String? ?? '';
        _model = event['model'] as String? ?? '';
        _commands
          ..clear()
          ..addAll([
            for (final c in (event['commands'] as List? ?? const []))
              SessionCommand(
                c['name'] as String,
                c['description'] as String,
                allowWhileRunning: c['allowWhileRunning'] as bool? ?? false,
                inputPrefix: c['inputPrefix'] as String?,
              ),
          ]);
        if (!_started.isCompleted) _started.complete();
      case 'status':
        _status = _statusFromEvent(event);
        _notifyStatus();
      case 'snapshot':
        _snapshot = _WireSnapshot(event, _status,
            throughSeq: (event['throughSeq'] as num?)?.toInt() ?? _throughSeq,
            requests: [
              for (final request in _requests.values) request.snapshot,
            ]);
        _throughSeq = _snapshot.throughSeq;
        for (final attachment in _attachments.toList()) {
          attachment._offer(_snapshot);
        }
        _notifyQuestions();
      case 'entry':
        final entry = Map<String, Object?>.from(event['entry'] as Map);
        _entries.add(entry);
        final seq = (entry['seq'] as num?)?.toInt();
        if (seq != null && seq > _throughSeq) _throughSeq = seq;
      case 'notice':
        _notices.add(SessionNotice.of(
            seq: (event['seq'] as num).toInt(),
            afterHistorySeq: (event['afterHistorySeq'] as num).toInt(),
            text: event['text'] as String,
            truncated: event['truncated'] as bool? ?? false));
        final seq = (event['seq'] as num?)?.toInt();
        if (seq != null && seq > _throughNoticeSeq) _throughNoticeSeq = seq;
      case 'receipt':
        _requests[event['id'] as String]?._applyReceipt(event);
      case 'cancel':
      case 'question-result':
      case 'approval-result':
      case 'commands':
      case 'settings':
      case 'history-page':
      case 'notice-page':
      case 'suggestions':
        _settleQueries(event);
    }
  }

  SessionStatus _statusFromEvent(Map<String, dynamic> event) => SessionStatus(
      id: _status.id,
      model: _model,
      workingDirectory: '',
      running: event['running'] as bool? ?? false,
      busy: event['busy'] as bool? ?? false,
      stopping: event['stopping'] as bool? ?? false,
      closed: event['closed'] as bool? ?? false,
      acceptsInput: event['acceptsInput'] as bool? ?? true,
      pendingInputCount: (event['pendingInputCount'] as num?)?.toInt() ?? 0,
      cancellableWork: [
        for (final work in (event['work'] as List? ?? const []))
          SessionWork(work['id'] as String, work['kind'] as String),
      ]);

  void _notifyStatus() {
    for (final entry in _statusListeners.entries.toList()) {
      if (!_statusListeners.containsKey(entry.key)) continue;
      try {
        entry.value(_status);
      } catch (_) {
        _statusListeners.remove(entry.key);
      }
    }
  }

  void _notifyQuestions() {
    final pending = questions.pending;
    for (final entry in _questionListeners.entries.toList()) {
      if (!_questionListeners.containsKey(entry.key)) continue;
      try {
        entry.value(pending);
      } catch (_) {
        _questionListeners.remove(entry.key);
      }
    }
  }

  /// Sends one op and completes with the first event of [responseType]
  /// whose `for` echoes the op's correlation id (or that simply matches
  /// when the op carries none).
  Future<Map<String, dynamic>> _query(
      Map<String, Object?> request, String responseType) {
    final id = request['id'] as String?;
    final waiter =
        _QueryWaiter(responseType, id is String ? id : null, Completer());
    _queries.add(waiter);
    _send(request);
    return waiter.done.future.timeout(const Duration(seconds: 30),
        onTimeout: () {
      _queries.remove(waiter);
      throw TimeoutException('no $responseType for ${id ?? request['op']}');
    });
  }

  void _settleQueries(Map<String, dynamic> event) {
    final echoed = event['for'];
    for (final waiter in _queries.toList()) {
      if (waiter.type != event['type']) continue;
      if (waiter.forId != null &&
          echoed != null &&
          echoed != waiter.forId) continue;
      _queries.remove(waiter);
      if (!waiter.done.isCompleted) waiter.done.complete(event);
    }
  }

  void _checkOpen() {
    if (_closed) throw StateError('session connection is closed');
  }

  Future<SessionHistoryPage> fetchHistory({int afterSeq = -1, int limit = 128}) async {
    _checkOpen();
    final response = await _query({
      'op': 'history',
      'id': 'history-${++_querySeq}',
      'afterSeq': afterSeq,
      'limit': limit,
    }, 'history-page');
    return SessionHistoryPage.of(
        epoch: _epoch,
        throughSeq: (response['nextAfterSeq'] as num?)?.toInt() ?? afterSeq,
        nextAfterSeq: (response['nextAfterSeq'] as num?)?.toInt() ?? afterSeq,
        hasMore: response['hasMore'] as bool? ?? false,
        entries: [
          for (final entry in (response['entries'] as List? ?? const []))
            Map<String, Object?>.from(entry as Map),
        ]);
  }

  var _querySeq = 0;

  // ---- SessionConnection --------------------------------------------------
  @override
  SessionRole get role => SessionRole.controller;

  @override
  late final ClientAccess access = ClientAccess(
      canControl: true,
      checkActive: () {
        _checkOpen();
        if (!_started.isCompleted) throw StateError('engine is not ready');
      });

  @override
  bool get canControl => !_closed;

  @override
  QuestionClient get questions => _questions;
  late final _PipesQuestionClient _questions = _PipesQuestionClient(this);

  @override
  SessionAttachment attach() {
    _checkOpen();
    final attachment = _PipesAttachment(this);
    _attachments.add(attachment);
    return attachment;
  }

  @override
  SessionHistoryPage history(
      {required SessionSnapshot snapshot,
      int afterSeq = -1,
      int limit = 128}) {
    _checkOpen();
    final through = snapshot.throughSeq;
    final page = <Map<String, Object?>>[];
    var next = afterSeq;
    for (final entry in _entries) {
      final seq = (entry['seq'] as num?)?.toInt() ?? -1;
      if (seq <= afterSeq || seq > through) continue;
      if (page.length >= limit) break;
      page.add(entry);
      next = seq;
    }
    return SessionHistoryPage.of(
        epoch: _epoch,
        throughSeq: through,
        nextAfterSeq: page.isEmpty ? afterSeq : next,
        hasMore: page.isNotEmpty && next < through,
        entries: page);
  }

  @override
  SessionNoticePage notices(
      {required SessionSnapshot snapshot,
      int afterSeq = -1,
      int limit = 128}) {
    _checkOpen();
    final through = snapshot.throughNoticeSeq;
    final page = <SessionNotice>[];
    var next = afterSeq;
    for (final notice in _notices) {
      if (notice.seq <= afterSeq || notice.seq > through) continue;
      if (page.length >= limit) break;
      page.add(notice);
      next = notice.seq;
    }
    return SessionNoticePage.of(
        entries: page,
        nextAfterSeq: page.isEmpty ? afterSeq : next,
        hasMore: page.isNotEmpty && next < through);
  }

  @override
  SessionStatus get status => _status;

  @override
  List<String> get inputHistory {
    final recorded = {
      for (final entry in _entries)
        if (entry['type'] == 'input_recorded') entry['turn_id'] as String,
    };
    return [
      for (final entry in _entries)
        if (entry['type'] == 'input_recorded' &&
            (entry['text'] as String?)!.isNotEmpty)
          entry['text'] as String
        else if (entry['type'] == 'message_appended' &&
            (entry['message'] as Map)['role'] == 'user' &&
            !recorded.contains(entry['turn_id'] as String))
          for (final block in ((entry['message'] as Map)['content'] as List))
            if (block is Map &&
                block['type'] == 'text' &&
                (block['text'] as String?)!.isNotEmpty)
              block['text'] as String,
    ];
  }

  @override
  List<SessionCommand> get commands => List.unmodifiable(_commands);

  @override
  SessionCommandCall? commandFor(String line) {
    _checkOpen();
    final trimmed = line.trim();
    if (!trimmed.startsWith('/')) return null;
    final rest = trimmed.substring(1);
    final split = RegExp(r'\s').firstMatch(rest);
    final name = split == null ? rest : rest.substring(0, split.start);
    final argument = split == null ? '' : rest.substring(split.end).trim();
    final exact = _commands.where((c) => c.name == name).toList();
    if (exact.isNotEmpty) {
      return SessionCommandCall(exact.single, argument);
    }
    final prefixed =
        _commands.where((c) => c.name.startsWith(name)).toList();
    if (prefixed.length == 1) return SessionCommandCall(prefixed.single, argument);
    return null;
  }

  @override
  Future<List<String>> completeCommand(String name, String prefix) async {
    _checkOpen();
    final response = await _query({
      'op': 'complete',
      'id': 'complete-${++_querySeq}',
      'name': name,
      'prefix': prefix,
    }, 'suggestions');
    return [for (final s in (response['suggestions'] as List? ?? const [])) s as String];
  }

  @override
  Future<SessionResult> submit(String line) async {
    final request =
        submitRequest(line, id: requestWindow.id('p-${++_querySeq}'));
    final snapshot = await request.completed;
    return snapshot.result ?? const SessionResult();
  }

  @override
  SessionRequestWindow get requestWindow {
    _checkOpen();
    return SessionRequestWindow(_epoch, 0);
  }

  @override
  SessionRequest? request(SessionRequestId id) => _requests[id.value];

  @override
  SessionRequest submitOperation(String plugin, String operation,
      {Map<String, Object?> arguments = const {},
      required SessionRequestId id}) {
    _checkOpen();
    access.requireControl();
    return _requests.putIfAbsent(id.value, () {
      final request = PipesRequest(id.value, this);
      _send({
        'op': 'operation',
        'plugin': plugin,
        'operation': operation,
        'arguments': arguments,
        'id': id.value,
      });
      return request;
    });
  }

  @override
  SessionOutputPage output(SessionRequestId id, {int afterSeq = -1}) =>
      throw UnsupportedError(
          'request output does not cross the pipes protocol');

  @override
  SessionRequest submitRequest(String line, {required SessionRequestId id}) {
    _checkOpen();
    access.requireControl();
    return _requests.putIfAbsent(id.value, () {
      final request = PipesRequest(id.value, this);
      _send({'op': 'submit', 'id': id.value, 'line': line});
      return request;
    });
  }

  @override
  bool offerInput(String line) => throw UnsupportedError(
      'synchronous offer has no pipes semantics; use submitRequest');

  @override
  Future<SessionResult>? offerCommand(String line) => throw UnsupportedError(
      'synchronous offer has no pipes semantics; use submitRequest');

  @override
  bool cancel(Iterable<String> workIds, {String reason = 'client'}) {
    _checkOpen();
    final ids = workIds.toList();
    for (final work in ids) {
      _send({'op': 'cancel', 'work': work, 'reason': reason});
    }
    return _status.cancellableWork.any((work) => ids.contains(work.id));
  }

  @override
  void Function() listen(void Function(SessionStatus) listener) {
    final key = Object();
    _statusListeners[key] = listener;
    try {
      listener(_status);
    } catch (_) {
      _statusListeners.remove(key);
      rethrow;
    }
    return () => _statusListeners.remove(key);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _statusListeners.clear();
    _questionListeners.clear();
    for (final attachment in _attachments.toList()) {
      attachment.close();
    }
    for (final request in _requests.values) {
      request._fail('session connection is closed');
    }
    _subscription.cancel();
  }
}

/// One admitted request over the wire: the receipt snapshot updates as
/// `receipt` events arrive; `completed` resolves on the terminal state.
final class PipesRequest implements SessionRequest {
  PipesRequest(this.id, this._connection) {
    _snapshot = SessionRequestSnapshot(
        SessionRequestWindow(_connection._epoch, 0).id(id),
        SessionRequestState.accepted);
  }

  final String id;
  final PipesConnection _connection;
  late SessionRequestSnapshot _snapshot;
  final _done = Completer<SessionRequestSnapshot>();

  @override
  SessionRequestSnapshot get snapshot => _snapshot;

  @override
  Future<SessionRequestSnapshot> get completed => _done.future;

  void _applyReceipt(Map<String, dynamic> event) {
    if (_done.isCompleted) return;
    final state = switch (event['state']) {
      'accepted' => SessionRequestState.accepted,
      'running' => SessionRequestState.running,
      'completed' => SessionRequestState.completed,
      'failed' => SessionRequestState.failed,
      'cancelled' => SessionRequestState.cancelled,
      'rejected' => SessionRequestState.rejected,
      _ => SessionRequestState.accepted,
    };
    final stopReason = switch (event['stopReason']) {
      'complete' => StopReason.complete,
      'cancelled' => StopReason.cancelled,
      'error' => StopReason.error,
      _ => state == SessionRequestState.completed ? StopReason.complete : null,
    };
    final detail = event['detail'] as String? ?? '';
    _snapshot = SessionRequestSnapshot(
        SessionRequestWindow(_connection._epoch, 0).id(id), state,
        inputId: event['inputId'] as String?,
        workId: event['workId'] as String?,
        result: stopReason == null && detail.isEmpty
            ? null
            : SessionResult(stopReason: stopReason, detail: detail),
        resultTruncated: event['resultTruncated'] as bool? ?? false);
    if (_snapshot.terminal) {
      _done.complete(_snapshot);
      _connection._notifyStatus();
    }
  }

  void _fail(String detail) {
    if (_done.isCompleted) return;
    _snapshot = SessionRequestSnapshot(
        SessionRequestWindow(_connection._epoch, 0).id(id),
        SessionRequestState.failed,
        result: const SessionResult(
            stopReason: StopReason.error, detail: 'Connection lost.'));
    _done.complete(_snapshot);
  }
}

final class _PipesQuestionClient implements QuestionClient {
  _PipesQuestionClient(this._connection);
  final PipesConnection _connection;

  @override
  bool get canAnswer => !_connection._closed;

  @override
  List<SessionQuestion> get pending => _connection._snapshot.questions;

  @override
  bool answer(String id, String text) {
    if (_connection._closed) return false;
    final pending = _connection._snapshot.questions.any((q) => q.id == id);
    _connection._send({'op': 'answer', 'id': id, 'text': text});
    return pending;
  }

  @override
  bool dismiss(String id) {
    if (_connection._closed) return false;
    final pending = _connection._snapshot.questions.any((q) => q.id == id);
    _connection._send({'op': 'dismiss', 'id': id});
    return pending;
  }

  @override
  void Function() listen(void Function(List<SessionQuestion>) listener) {
    final key = Object();
    _connection._questionListeners[key] = listener;
    try {
      listener(pending);
    } catch (_) {
      _connection._questionListeners.remove(key);
      rethrow;
    }
    return () => _connection._questionListeners.remove(key);
  }

  @override
  void close() {
    // The pipes question client owns no engine resources; the connection's
    // close clears its listeners.
    _connection._questionListeners.clear();
  }
}

final class _PipesAttachment implements SessionAttachment {
  _PipesAttachment(this._connection) : initial = _connection._snapshot;
  final PipesConnection _connection;
  @override
  final SessionSnapshot initial;
  SessionUpdate? _pending;
  Completer<SessionUpdate?>? _waiting;
  bool _closed = false;
  int _lastOffered = -1;

  @override
  int get bufferedUpdates => _pending == null ? 0 : 1;

  @override
  Future<SessionUpdate?> next() {
    if (_waiting != null) {
      throw StateError('Only one attachment read at a time');
    }
    if (_closed) return Future.value(null);
    final pending = _pending;
    if (pending != null) {
      _pending = null;
      return Future.value(pending);
    }
    return (_waiting = Completer<SessionUpdate?>()).future;
  }

  void _offer(SessionSnapshot snapshot) {
    if (_closed || snapshot.cursor.revision <= _lastOffered) return;
    _lastOffered = snapshot.cursor.revision;
    final waiter = _waiting;
    if (waiter != null) {
      _waiting = null;
      waiter.complete(SessionUpdate(snapshot, coalesced: false));
    } else {
      _pending = SessionUpdate(snapshot, coalesced: _pending != null);
    }
  }

  @override
  SessionHistoryPage history(
      {required SessionSnapshot snapshot,
      int afterSeq = -1,
      int limit = 128}) {
    if (_closed) throw StateError('Attachment is closed');
    if (limit < 1 || limit > 512 || afterSeq < -1) {
      throw RangeError('Invalid history page bounds');
    }
    return _connection.history(snapshot: snapshot, afterSeq: afterSeq, limit: limit);
  }

  @override
  SessionNoticePage notices(
      {required SessionSnapshot snapshot,
      int afterSeq = -1,
      int limit = 128}) {
    if (_closed) throw StateError('Attachment is closed');
    if (limit < 1 || limit > 512 || afterSeq < -1) {
      throw RangeError('Invalid notice page bounds');
    }
    return _connection.notices(snapshot: snapshot, afterSeq: afterSeq, limit: limit);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _pending = null;
    _waiting?.complete(null);
    _waiting = null;
    _connection._attachments.remove(this);
  }
}

/// The snapshot before the engine's first one arrives: empty, idle.
final class _EmptySnapshot implements SessionSnapshot {
  const _EmptySnapshot();
  @override
  SessionCursor get cursor => const SessionCursor('', -1);
  @override
  SessionStatus get status => SessionStatus(
      id: '',
      model: '',
      workingDirectory: '',
      running: false,
      busy: false,
      acceptsInput: true,
      pendingInputCount: 0,
      stopping: false,
      closed: false,
      cancellableWork: const []);
  @override
  int get throughSeq => -1;
  @override
  bool get historyPublicationFailed => false;
  @override
  int get throughNoticeSeq => -1;
  @override
  List<Input> get pendingInputs => const [];
  @override
  List<SessionRequestSnapshot> get requests => const [];
  @override
  List<SessionWork> get activeWork => const [];
  @override
  List<SessionQuestion> get questions => const [];
  @override
  List<String> get plugins => const [];
  @override
  List<String> get unavailableFeatures => const [];
  @override
  Map<String, Object?> get features => const {};
  @override
  Map<String, Object?> get activeTools => const {};
}

/// The client-side composition of a `snapshot` event with the latest
/// status and the receipts this client tracks.
final class _WireSnapshot implements SessionSnapshot {
  _WireSnapshot(
    Map<String, dynamic> event,
    SessionStatus status, {
    required int throughSeq,
    required List<SessionRequestSnapshot> requests,
  })  : cursor = SessionCursor(
            event['epoch'] as String? ?? '',
            (event['revision'] as num?)?.toInt() ?? -1),
        status = status,
        throughSeq = throughSeq,
        historyPublicationFailed = false,
        throughNoticeSeq = (event['throughNoticeSeq'] as num?)?.toInt() ?? -1,
        pendingInputs = [
          for (final input in (event['pendingInputs'] as List? ?? const []))
            Input((input as Map)['line'] as String,
                id: input['id'] as String? ?? ''),
        ],
        requests = requests,
        activeWork = status.cancellableWork,
        questions = [
          for (final q in (event['questions'] as List? ?? const []))
            SessionQuestion(
              (q as Map)['id'] as String,
              q['prompt'] as String,
              q['expiresAt'] == null
                  ? null
                  : DateTime.parse(q['expiresAt'] as String),
            ),
        ],
        plugins = [
          for (final plugin in (event['plugins'] as List? ?? const []))
            plugin as String,
        ],
        unavailableFeatures = [
          for (final feature
              in (event['unavailableFeatures'] as List? ?? const []))
            feature as String,
        ],
        features = Map.unmodifiable(
            (event['features'] as Map?)?.cast<String, Object?>() ?? const {}),
        activeTools = Map.unmodifiable(
            (event['activeTools'] as Map?)?.cast<String, Object?>() ?? const {});

  @override
  final SessionCursor cursor;
  @override
  final SessionStatus status;
  @override
  final int throughSeq;
  @override
  final bool historyPublicationFailed;
  @override
  final int throughNoticeSeq;
  @override
  final List<Input> pendingInputs;
  @override
  final List<SessionRequestSnapshot> requests;
  @override
  final List<SessionWork> activeWork;
  @override
  final List<SessionQuestion> questions;
  @override
  final List<String> plugins;
  @override
  final List<String> unavailableFeatures;
  @override
  final Map<String, Object?> features;
  @override
  final Map<String, Object?> activeTools;
}

final class _QueryWaiter {
  _QueryWaiter(this.type, this.forId, this.done);
  final String type;
  final String? forId;
  final Completer<Map<String, dynamic>> done;
}
