part of '../tina_approvals.dart';

typedef CommandPatternSuggestion = ({
  String? pattern,
  String? explanation,
  String? failure
});
typedef SuggestCommandPattern = Future<CommandPatternSuggestion> Function(
    ApprovalRequest request, Future<void> whenCancelled);

/// Session-owned delivery for independently attached approval views.
/// New requests without an interactive responder fail closed. Detaching a view
/// leaves existing requests with the session's cancellation and expiry policy.
final class AttachmentApprovalChannel extends AgentPlugin
    implements ApprovalChannel {
  AttachmentApprovalChannel({this.suggestCommandPattern});
  final SuggestCommandPattern? suggestCommandPattern;
  @override
  String get id => 'tina/approvals-tui';
  final _pending = <String, _PresentedQuestion>{};
  final _listeners = <Object, void Function(ApprovalQuestion)>{};
  bool _closed = false;
  late final interaction = ApprovalInteraction._(this);

  @override
  Future<void> deliver(ApprovalTicket ticket) async {
    if (!ticket.isActive) return;
    if (_closed || _listeners.isEmpty) {
      ticket.respond(ApprovalDecision.deny);
      return;
    }
    final question = _PresentedQuestion(this, ticket);
    _pending[ticket.request.id] = question;
    unawaited(ticket.done.then((_) => _pending.remove(ticket.request.id)));
    for (final entry in _listeners.entries.toList()) {
      if (!_listeners.containsKey(entry.key) || !question.isActive) continue;
      try {
        entry.value(question);
      } catch (_) {
        _listeners.remove(entry.key);
      }
    }
    if (_listeners.isEmpty && question.isActive)
      ticket.respond(ApprovalDecision.deny);
  }

  void Function() _listen(void Function(ApprovalQuestion) listener) {
    if (_closed) throw StateError('Approval channel is closed');
    final owner = Object();
    _listeners[owner] = listener;
    try {
      for (final question in _pending.values.toList()) {
        if (question.isActive) listener(question);
      }
    } catch (_) {
      _listeners.remove(owner);
      rethrow;
    }
    return () => _listeners.remove(owner);
  }

  @override
  void closeSession() {
    if (_closed) return;
    _closed = true;
    for (final question in _pending.values.toList()) {
      question._ticket.respond(ApprovalDecision.deny);
    }
    _pending.clear();
    _listeners.clear();
  }
}

/// Presentation can answer one current question and request a draft regex. It
/// cannot deliver requests, alter the channel, or close the approval service.
final class ApprovalInteraction {
  ApprovalInteraction._(this._channel);
  final AttachmentApprovalChannel _channel;
  List<ApprovalRequest> get pending => List.unmodifiable(
      _channel._pending.values.where((q) => q.isActive).map((q) => q.request));
  void Function() listen(void Function(ApprovalQuestion) listener) =>
      _channel._listen(listener);
  Future<CommandPatternSuggestion> suggest(
      ApprovalRequest request, Future<void> cancelled) async {
    final question = _channel._pending[request.id];
    final suggest = _channel.suggestCommandPattern;
    if (question?.isActive != true || suggest == null) {
      return (
        pattern: null,
        explanation: null,
        failure: 'suggestion unavailable'
      );
    }
    return suggest(
        question!.request, Future.any([cancelled, question.done.then((_) {})]));
  }
}

final class _PresentedQuestion implements ApprovalQuestion {
  _PresentedQuestion(this._channel, this._ticket);
  final AttachmentApprovalChannel _channel;
  final ApprovalTicket _ticket;
  @override
  ApprovalRequest get request => _ticket.request;
  @override
  Future<ApprovalDecision> get done => _ticket.done;
  @override
  bool get isActive =>
      !_channel._closed &&
      _ticket.isActive &&
      identical(_channel._pending[request.id], this);
  @override
  bool respond(ApprovalDecision decision, {String? commandPattern}) =>
      isActive && _ticket.respond(decision, commandPattern: commandPattern);
}

Map<String, Object?> _freezeApprovalDetails(Map<String, Object?> value) =>
    Map.unmodifiable({
      for (final entry in value.entries)
        entry.key: _freezeApprovalValue(entry.value)
    });
Object? _freezeApprovalValue(Object? value) => switch (value) {
      Map value => Map.unmodifiable({
          for (final entry in value.entries)
            entry.key: _freezeApprovalValue(entry.value)
        }),
      List value => List.unmodifiable(value.map(_freezeApprovalValue)),
      _ => value,
    };
