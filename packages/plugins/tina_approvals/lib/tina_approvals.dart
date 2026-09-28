library;

import 'dart:async';
import 'dart:math';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';

/// No channel, UI or filesystem types appear in the request protocol.
enum ApprovalDecision { allow, allowAlways, deny }

final class ApprovalRequest {
  const ApprovalRequest(
      {required this.id,
      required this.operation,
      required this.target,
      required this.reason});
  final String id;
  final String operation;
  final String target;
  final String reason;
}

abstract interface class ApprovalRequester {
  Future<ApprovalDecision> request(
      {required String operation,
      required String target,
      required String reason});
}

/// A channel must authenticate remote responders before accepting their answers.
/// Delivery failures deny the request. Completing delivery is not an approval.
abstract interface class ApprovalChannel {
  Future<void> deliver(ApprovalTicket ticket);
}

/// A single pending request. A channel may reply once, while it remains active.
/// [done] also signals cancellation, expiry and shutdown to channel resources.
final class ApprovalTicket {
  ApprovalTicket._(this.request, this._respond, this.done);
  final ApprovalRequest request;
  final bool Function(ApprovalDecision) _respond;
  final Future<ApprovalDecision> done;
  bool _active = true;
  bool get isActive => _active;
  bool respond(ApprovalDecision decision) => _respond(decision);
}

const approvalRequester =
    PluginCapability<ApprovalRequester>('tina/approval-requester');
const approvalChannel =
    PluginCapability<ApprovalChannel>('tina/approval-channel');

PluginDefinition<C> approvalsDefinition<C>() =>
    PluginDefinition.dependingOn<C, ApprovalChannel>('tina/approvals',
        dependency: approvalChannel,
        create: (_, channel) => ApprovalsPlugin(channel: channel),
        provides: [approvalRequester]);

/// Owns correlation, expiry and cancellation; enforcement stays with the caller.
final class ApprovalsPlugin extends AgentPlugin implements ApprovalRequester {
  ApprovalsPlugin(
      {required this.channel, this.timeout = const Duration(minutes: 5)});
  final ApprovalChannel channel;
  final Duration timeout;
  final _pending = <String, ApprovalTicket>{};
  final _prefix = List.generate(16,
          (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'))
      .join();
  int _sequence = 0;
  int _turn = 0;
  bool _closed = false;
  bool Function()? _turnCancelled;
  @override
  String get id => 'tina/approvals';
  @override
  int get order => 5;
  Iterable<ApprovalRequest> get pending =>
      List.unmodifiable(_pending.values.map((t) => t.request));

  @override
  Future<ApprovalDecision> request(
      {required String operation,
      required String target,
      required String reason}) {
    if (_closed || (_turnCancelled?.call() ?? false)) {
      return Future.value(ApprovalDecision.deny);
    }
    final request = ApprovalRequest(
        id: '$_prefix-${++_sequence}',
        operation: operation,
        target: target,
        reason: reason);
    final result = Completer<ApprovalDecision>();
    Timer? timer;
    late final ApprovalTicket ticket;
    ticket = ApprovalTicket._(request, (decision) {
      if (!ticket._active) return false;
      final invalid = _closed || (_turnCancelled?.call() ?? false);
      ticket._active = false;
      _pending.remove(request.id);
      timer?.cancel();
      result.complete(invalid ? ApprovalDecision.deny : decision);
      return !invalid;
    }, result.future);
    _pending[request.id] = ticket;
    timer = Timer(timeout, () => ticket.respond(ApprovalDecision.deny));
    unawaited(Future.sync(() => channel.deliver(ticket)).catchError((Object _) {
      ticket.respond(ApprovalDecision.deny);
    }));
    return result.future;
  }

  void _denyPending() {
    for (final ticket in _pending.values.toList()) {
      ticket.respond(ApprovalDecision.deny);
    }
  }

  @override
  void onInput(TurnContext context) {
    final turn = ++_turn;
    _turnCancelled = () => context.cancelled;
    unawaited(context.whenCancelled.then((_) {
      if (_turn == turn) _denyPending();
    }));
  }

  @override
  void onTurnEnd(TurnContext context) {
    _denyPending();
    _turn++;
    _turnCancelled = null;
  }

  @override
  void closeSession() {
    _closed = true;
    _denyPending();
  }
}

/// Transport adapter for a daemon, SMS gateway or test. One subscriber owns
/// delivery. The adapter authenticates its input before calling [respond].
/// Requests are in-memory and expire with the owning approval service/session.
final class StreamApprovalChannel extends AgentPlugin
    implements ApprovalChannel {
  StreamApprovalChannel({this.id = 'tina/approvals-stream'}) {
    _requests.onCancel = _denyPending;
  }
  @override
  final String id;
  final _requests = StreamController<ApprovalRequest>(sync: true);
  final _pending = <String, ApprovalTicket>{};
  bool _closed = false;
  Stream<ApprovalRequest> get requests => _requests.stream;
  @override
  Future<void> deliver(ApprovalTicket ticket) async {
    if (_closed || !_requests.hasListener) {
      ticket.respond(ApprovalDecision.deny);
      return;
    }
    if (!ticket.isActive) return;
    _pending[ticket.request.id] = ticket;
    unawaited(ticket.done.then((_) => _pending.remove(ticket.request.id)));
    _requests.add(ticket.request);
  }

  bool respond(String id, ApprovalDecision decision) =>
      _pending[id]?.respond(decision) ?? false;
  void _denyPending() {
    for (final ticket in _pending.values.toList()) {
      ticket.respond(ApprovalDecision.deny);
    }
    _pending.clear();
  }

  @override
  void closeSession() {
    if (_closed) return;
    _closed = true;
    _denyPending();
    unawaited(_requests.close());
  }
}
