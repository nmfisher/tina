import 'dart:async';
import 'dart:math';

/// Ordinary text questions, separate from permission and approval requests.
final class SessionQuestion {
  const SessionQuestion(this.id, this.prompt, this.expiresAt);
  final String id, prompt;
  final DateTime? expiresAt;
}

enum QuestionDisposition { answered, cancelled, expired, unavailable, closed }

final class QuestionResult {
  const QuestionResult(this.disposition, [this.text = '']);
  final QuestionDisposition disposition;
  final String text;
}

/// Session-owned questions. Interactive requests survive periods without a
/// client; unattended requests settle immediately without inventing an answer.
/// Only an exact, still-pending ID can be answered. IDs are not reused when a
/// session is resumed or another service is constructed.
final class SessionQuestions {
  SessionQuestions(
      {this.interactive = true, this.timeout = const Duration(minutes: 5)}) {
    if (timeout != null && timeout!.isNegative) {
      throw ArgumentError.value(timeout, 'timeout', 'must not be negative');
    }
  }
  final bool interactive;
  final Duration? timeout;
  final String _epoch = List.generate(
      4,
      (_) => Random.secure()
          .nextInt(1 << 32)
          .toRadixString(16)
          .padLeft(8, '0')).join();
  final _scopeKey = Object();
  final _pending = <String, _PendingQuestion>{};
  final _clients = <QuestionClient>{};
  final _listeners = <Object, void Function()>{};
  int _nextId = 0;
  bool _closed = false, _notificationQueued = false;

  List<SessionQuestion> get pending =>
      List.unmodifiable(_pending.values.map((item) => item.question));

  QuestionClient connect() {
    if (_closed) throw StateError('questions are closed');
    final client = QuestionClient._(this);
    _clients.add(client);
    return client;
  }

  /// The host associates asynchronous command/turn work with its own scope.
  /// A late continuation retains its retired scope and cannot ask a successor
  /// operation's question. Clients never receive this cancellation authority.
  QuestionScope openScope() => QuestionScope._(this);
  QuestionScope? get currentScope => Zone.current[_scopeKey] as QuestionScope?;

  Future<QuestionResult> ask(String prompt) {
    if (_closed)
      return Future.value(const QuestionResult(QuestionDisposition.closed));
    if (!interactive)
      return Future.value(
          const QuestionResult(QuestionDisposition.unavailable));
    final scope = currentScope;
    if (scope?._cancelled == true) {
      return Future.value(const QuestionResult(QuestionDisposition.cancelled));
    }
    final id = 'question-$_epoch-${++_nextId}';
    final duration = timeout;
    final question = _PendingQuestion(
        SessionQuestion(id, prompt,
            duration == null ? null : DateTime.now().toUtc().add(duration)),
        scope);
    _pending[id] = question;
    scope?._pending.add(id);
    if (duration != null) {
      question.timer = Timer(duration,
          () => _settle(id, const QuestionResult(QuestionDisposition.expired)));
    }
    _changed();
    return question.done.future;
  }

  bool _settle(String id, QuestionResult result) {
    final pending = _pending.remove(id);
    if (pending == null) return false;
    pending.timer?.cancel();
    pending.scope?._pending.remove(id);
    pending.done.complete(result);
    _changed();
    return true;
  }

  /// Owner observation, used by the host to update cancellable work metadata.
  void Function() listen(void Function() listener) {
    if (_closed) throw StateError('questions are closed');
    final key = Object();
    _listeners[key] = listener;
    return () => _listeners.remove(key);
  }

  void _changed() {
    if (_notificationQueued) return;
    _notificationQueued = true;
    scheduleMicrotask(() {
      _notificationQueued = false;
      for (final entry in _listeners.entries.toList()) {
        if (!_listeners.containsKey(entry.key)) continue;
        try {
          entry.value();
        } catch (_) {
          _listeners.remove(entry.key);
        }
      }
      for (final client in _clients.toList()) client._notify();
    });
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final id in _pending.keys.toList()) {
      _settle(id, const QuestionResult(QuestionDisposition.closed));
    }
    _listeners.clear();
    _changed();
  }
}

/// An owner-side lifetime for questions asked by one asynchronous operation.
final class QuestionScope {
  QuestionScope._(this._questions);
  final SessionQuestions _questions;
  final _pending = <String>{};
  bool _cancelled = false;
  bool get hasPending => _pending.isNotEmpty;
  Future<T> run<T>(FutureOr<T> Function() action) =>
      runZoned(() => Future.sync(action),
          zoneValues: {_questions._scopeKey: this});
  void cancel() {
    _cancelled = true;
    for (final id in _pending.toList()) {
      _questions._settle(
          id, const QuestionResult(QuestionDisposition.cancelled));
    }
  }
}

/// A disposable in-process client: immutable pending snapshots and responses
/// by question ID. Closing it releases observers, leaving requests with their
/// session. Cancellation is an explicit user action, separate from detach.
final class QuestionClient {
  QuestionClient._(this._questions);
  final SessionQuestions _questions;
  final _listeners = <Object, void Function(List<SessionQuestion>)>{};
  bool _closed = false;

  List<SessionQuestion> get pending => _closed
      ? const []
      : List.unmodifiable(
          _questions._pending.values.map((item) => item.question));

  bool answer(String id, String text) =>
      !_closed &&
      _questions._settle(
          id, QuestionResult(QuestionDisposition.answered, text));
  bool dismiss(String id) =>
      !_closed &&
      _questions._settle(
          id, const QuestionResult(QuestionDisposition.cancelled));

  void Function() listen(void Function(List<SessionQuestion>) listener) {
    if (_closed) throw StateError('question client is closed');
    final key = Object();
    _listeners[key] = listener;
    try {
      listener(pending);
    } catch (_) {
      _listeners.remove(key);
      rethrow;
    }
    return () => _listeners.remove(key);
  }

  void _notify() {
    if (_closed) return;
    for (final entry in _listeners.entries.toList()) {
      if (!_listeners.containsKey(entry.key)) continue;
      // Re-read for each listener: an earlier callback may have answered.
      try {
        entry.value(pending);
      } catch (_) {
        _listeners.remove(entry.key);
      }
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _listeners.clear();
    _questions._clients.remove(this);
  }
}

final class _PendingQuestion {
  _PendingQuestion(this.question, this.scope);
  final SessionQuestion question;
  final QuestionScope? scope;
  final done = Completer<QuestionResult>();
  Timer? timer;
}
