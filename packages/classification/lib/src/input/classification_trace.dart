import 'dart:async';
import 'dart:convert';

enum ClassificationExchangePhase { pending, complete, failed, cancelled }

/// Display-only decoded outcome. Scores and wire answers remain separate.
final class ClassificationOutcome {
  const ClassificationOutcome(this.label, {this.unclear = false});
  final String label;
  final bool unclear;
}

/// Session-local diagnostics, separate from the transcript and learned catalog.
/// Callers supply bodies only, never transport headers or provider credentials.
final class ClassificationTrace {
  ClassificationTrace({this.capacity = 32, this.payloadLimit = 65536}) {
    if (capacity < 1 || payloadLimit < 1) throw ArgumentError('Invalid limits');
  }
  final int capacity, payloadLimit;
  final _exchanges = <ClassificationExchange>[];
  final _changes = StreamController<void>.broadcast(sync: true);
  bool _closed = false;
  int _serial = 0;
  int _revision = 0;
  int get revision => _revision;
  List<ClassificationExchange> get exchanges => List.unmodifiable(_exchanges);
  Stream<void> get changes => _changes.stream;

  ClassificationExchange begin({
    required String inputId,
    required String title,
    required Object request,
    int? parentId,
    String? classifierId,
    String? classifierName,
    String? trigger,
    String? inputText,
    Map<String, Object?> questions = const {},
  }) {
    final exchange = ClassificationExchange._(
      this,
      ++_serial,
      inputId,
      title,
      _format(request),
      DateTime.now(),
      parentId,
      Map.unmodifiable(questions),
      classifierId ?? title,
      classifierName ?? title,
      trigger,
      inputText == null ? null : _clip(inputText),
    );
    if (!_closed) {
      _exchanges.add(exchange);
      if (_exchanges.length > capacity) _exchanges.removeAt(0);
      _notify();
    }
    return exchange;
  }

  String _format(Object value) => _clip(
    value is String ? value : const JsonEncoder.withIndent('  ').convert(value),
  );
  String _clip(String value) => value.length <= payloadLimit
      ? value
      : '${value.substring(0, payloadLimit)}\n[display truncated]';
  void _notify() {
    if (!_closed) {
      _revision++;
      _changes.add(null);
    }
  }

  void cancelPending(String inputId) {
    for (final exchange in _exchanges.toList()) {
      if (exchange.inputId == inputId)
        exchange.fail('cancelled', cancelled: true);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(_changes.close());
  }
}

final class ClassificationExchange {
  ClassificationExchange._(
    this._trace,
    this.id,
    this.inputId,
    this.title,
    this.request,
    this.started,
    this.parentId,
    this.questions,
    this.classifierId,
    this.classifierName,
    this.trigger,
    this.inputText,
  );
  final ClassificationTrace _trace;
  final int id;

  /// An actual dependency, never merely a preceding request.
  final int? parentId;

  /// Stable classifier identity and its user-facing name.
  final String classifierId, classifierName;
  final String? trigger, inputText;
  ClassificationOutcome? _outcome;
  ClassificationOutcome? get outcome => _outcome;

  /// The owner records the decoded result after evaluation, without changing
  /// classifier decisions. Cancelled/failed/closed runs reject late outcomes.
  void recordOutcome(ClassificationOutcome value) {
    if (_trace._closed || _phase != ClassificationExchangePhase.complete)
      return;
    _outcome = value;
    _trace._notify();
  }

  /// Question metadata survives clipping the displayed body at large catalogs.
  final Map<String, Object?> questions;
  Map<String, Object?> _answers = const {};
  Map<String, Object?> get answers => _answers;
  final String inputId, title, request;
  final DateTime started;
  String _response = '';
  String get response => _response;
  String? _error;
  String? get error => _error;
  DateTime? _finished;
  Duration? get elapsed => _finished?.difference(started);
  ClassificationExchangePhase _phase = ClassificationExchangePhase.pending;
  ClassificationExchangePhase get phase => _phase;
  bool get pending =>
      !_trace._closed && _phase == ClassificationExchangePhase.pending;

  void recordAnswers(Map<String, Object?> value) {
    if (!pending) return;
    _answers = Map.unmodifiable(value);
    _trace._notify();
  }

  /// A full wire response replaces streaming fragments; failed decoding can
  /// still leave a successful HTTP body's diagnostic text available.
  void receive(Object value) {
    if (!pending) return;
    _response = _trace._format(value);
    _trace._notify();
  }

  void append(String text) {
    if (!pending || _response.length > _trace.payloadLimit) return;
    _response = _trace._clip('$_response$text');
    _trace._notify();
  }

  void complete([Object? value]) {
    if (!pending) return;
    if (value != null) _response = _trace._format(value);
    _phase = ClassificationExchangePhase.complete;
    _finished = DateTime.now();
    _trace._notify();
  }

  void fail(String reason, {bool cancelled = false}) {
    if (!pending) return;
    _error = reason;
    _phase = cancelled
        ? ClassificationExchangePhase.cancelled
        : ClassificationExchangePhase.failed;
    _finished = DateTime.now();
    _trace._notify();
  }
}
