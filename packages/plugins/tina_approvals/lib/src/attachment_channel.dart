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
  final _listeners = <Object, _ApprovalListener>{};
  bool get _hasResponder =>
      _listeners.values.any((item) => item.access.canControl);
  bool _closed = false;
  late final interaction = ApprovalInteraction._(this);

  @override
  Future<void> deliver(ApprovalTicket ticket) async {
    if (!ticket.isActive) return;
    if (_closed || !_hasResponder) {
      ticket.respond(ApprovalDecision.deny);
      return;
    }
    final question = _PresentedQuestion(this, ticket);
    _pending[ticket.request.id] = question;
    unawaited(ticket.done.then((_) => _pending.remove(ticket.request.id)));
    for (final entry in _listeners.entries.toList()) {
      if (!_listeners.containsKey(entry.key) || !question.isActive) continue;
      try {
        entry.value
            .listener(_ClientApprovalQuestion(question, entry.value.access));
      } catch (_) {
        _listeners.remove(entry.key);
      }
    }
    if (!_hasResponder && question.isActive)
      ticket.respond(ApprovalDecision.deny);
  }

  void Function() _listen(
      void Function(ApprovalQuestion) listener, ClientAccess access) {
    if (_closed) throw StateError('Approval channel is closed');
    final owner = Object();
    _listeners[owner] = _ApprovalListener(listener, access);
    try {
      for (final question in _pending.values.toList()) {
        if (question.isActive)
          listener(_ClientApprovalQuestion(question, access));
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
  ApprovalInteraction._(this._channel, [this._access = const ClientAccess()]);
  final AttachmentApprovalChannel _channel;
  final ClientAccess _access;
  bool get canRespond => _access.canControl;
  ApprovalInteraction forClient(ClientAccess access) =>
      ApprovalInteraction._(_channel, _access.restrict(access));
  List<ApprovalRequest> get pending => List.unmodifiable(
      _channel._pending.values.where((q) => q.isActive).map((q) => q.request));
  void Function() listen(void Function(ApprovalQuestion) listener) =>
      _channel._listen(listener, _access);
  Future<CommandPatternSuggestion> suggest(
      ApprovalRequest request, Future<void> cancelled) async {
    _access.requireControl();
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

final class _ApprovalListener {
  _ApprovalListener(this.listener, this.access);
  final void Function(ApprovalQuestion) listener;
  final ClientAccess access;
}

/// Never hand an attachment the session's raw response ticket. This wrapper
/// checks the originating connection even if a view retains it after closing.
final class _ClientApprovalQuestion implements ApprovalQuestion {
  _ClientApprovalQuestion(this._question, this._access);
  final ApprovalQuestion _question;
  final ClientAccess _access;
  @override
  ApprovalRequest get request => _question.request;
  @override
  Future<ApprovalDecision> get done => _question.done;
  @override
  bool get isActive => _access.isActive && _question.isActive;
  @override
  bool respond(ApprovalDecision decision, {String? commandPattern}) {
    _access.requireControl();
    return _question.respond(decision, commandPattern: commandPattern);
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
