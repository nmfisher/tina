library;

import 'dart:async';
import 'dart:math';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'src/command_pattern.dart';
import 'src/directory_access.dart';
export 'src/command_pattern.dart';
export 'src/directory_access.dart';
part 'src/attachment_channel.dart';

/// No channel, UI or filesystem types appear in the request protocol.
enum ApprovalDecision {
  allow,
  allowAlways,
  allowWorkspace,
  allowGlobal,
  deny,
  allowReadsInDirectory,
  allowAlwaysAndReadsInDirectory,
  allowWritesInDirectory,
  allowAlwaysAndWritesInDirectory,

  /// "Always permit reads": approve this read-only ask and stop asking for
  /// future read-shaped ones. The scope (session or workspace) rides the
  /// answer's validated read [DirectoryAccessGrant]s, not a separate enum
  /// value. Only offered for asks whose missing permissions are reads.
  allowReadsAlways
}

/// A confirmation has only Yes/No; it cannot grant future requests.
enum ApprovalKind { permission, confirmation }

final class ApprovalRequest {
  const ApprovalRequest(
      {required this.id,
      required this.operation,
      required this.target,
      required this.reason,
      this.kind = ApprovalKind.permission,
      this.details = const {}});
  final String id;
  final String operation;
  final String target;
  final String reason;
  final ApprovalKind kind;

  /// Channel-neutral tool and execution context for presenting the request.
  final Map<String, Object?> details;
}

abstract interface class ApprovalRequester {
  /// [onCommandPattern] receives a validated rule only with an accepted human
  /// remembered-scope response. The requester persists it after checking that
  /// its own operation is still active; this callback never executes a command.
  Future<ApprovalDecision> request(
      {required String operation,
      required String target,
      required String reason,
      ApprovalKind kind = ApprovalKind.permission,
      Map<String, Object?> details = const {},
      void Function(String pattern)? onCommandPattern,
      void Function(List<DirectoryAccessGrant> grants)? onDirectoryGrants});
}

/// A channel must authenticate remote responders before accepting their answers.
/// Delivery failures deny the request. Completing delivery is not an approval.
abstract interface class ApprovalChannel {
  Future<void> deliver(ApprovalTicket ticket);
}

/// A single pending request. A channel may reply once, while it remains active.
/// [done] also signals cancellation, expiry and shutdown to channel resources.
abstract interface class ApprovalQuestion {
  ApprovalRequest get request;
  Future<ApprovalDecision> get done;
  bool get isActive;
  bool respond(ApprovalDecision decision,
      {String? commandPattern,
      List<DirectoryAccessGrant> directoryGrants = const []});
}

final class ApprovalTicket implements ApprovalQuestion {
  ApprovalTicket._(this.request, this._respond, this.done);
  final ApprovalRequest request;
  final bool Function(ApprovalDecision, String?, List<DirectoryAccessGrant>)
      _respond;
  final Future<ApprovalDecision> done;
  bool _active = true;
  bool get isActive => _active;
  bool respond(ApprovalDecision decision,
          {String? commandPattern,
          List<DirectoryAccessGrant> directoryGrants = const []}) =>
      _respond(decision, commandPattern, directoryGrants);
}

const approvalRequester =
    PluginCapability<ApprovalRequester>('tina/approval-requester');
const approvalChannel =
    PluginCapability<ApprovalChannel>('tina/approval-channel');

PluginDefinition<C> approvalsDefinition<C>() => PluginDefinition.dependingOn<C,
        ApprovalChannel>('tina/approvals',
    dependency: approvalChannel,
    create: (_, channel) => ApprovalsPlugin(channel: channel),
    provides: [approvalRequester],
    description:
        'Coordinates approval requests, responses, cancellation and expiry.');

/// Owns correlation, expiry and cancellation; enforcement stays with the caller.
final class ApprovalsPlugin extends AgentPlugin implements ApprovalRequester {
  ApprovalsPlugin({required this.channel, this.timeout});
  final ApprovalChannel channel;

  /// No deadline by default. Embedders may explicitly opt into expiry.
  final Duration? timeout;
  final _pending = <String, ApprovalTicket>{};
  final _observers = <Object, void Function()>{};

  /// Observe pending state without registering a responder or changing delivery
  /// authority. Observation never makes a headless ask interactive.
  void Function() listenPending(void Function() listener) {
    if (_closed) throw StateError('Approvals are closed');
    final key = Object();
    _observers[key] = listener;
    return () => _observers.remove(key);
  }

  void _changed() {
    for (final entry in _observers.entries.toList()) {
      if (!_observers.containsKey(entry.key)) continue;
      try {
        entry.value();
      } catch (_) {
        _observers.remove(entry.key);
      }
    }
  }

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
      required String reason,
      ApprovalKind kind = ApprovalKind.permission,
      Map<String, Object?> details = const {},
      void Function(String pattern)? onCommandPattern,
      void Function(List<DirectoryAccessGrant> grants)? onDirectoryGrants}) {
    if (_closed || (_turnCancelled?.call() ?? false)) {
      return Future.value(ApprovalDecision.deny);
    }
    final request = ApprovalRequest(
        id: '$_prefix-${++_sequence}',
        operation: operation,
        target: target,
        reason: reason,
        kind: kind,
        details: _freezeApprovalDetails(details));
    final result = Completer<ApprovalDecision>();
    Timer? timer;
    late final ApprovalTicket ticket;
    ticket =
        ApprovalTicket._(request, (decision, commandPattern, directoryGrants) {
      if (!ticket._active) return false;
      final invalid = _closed || (_turnCancelled?.call() ?? false);
      ticket._active = false;
      _pending.remove(request.id);
      _changed();
      timer?.cancel();
      final directoryGrant =
          decision == ApprovalDecision.allowReadsInDirectory ||
              decision == ApprovalDecision.allowAlwaysAndReadsInDirectory;
      final writeGrant = decision == ApprovalDecision.allowWritesInDirectory ||
          decision == ApprovalDecision.allowAlwaysAndWritesInDirectory;
      final persistentGrant = decision == ApprovalDecision.allowWorkspace ||
          decision == ApprovalDecision.allowGlobal;
      var invalidPattern = false;
      if (commandPattern != null) {
        try {
          final command = request.details['command_pattern_target'];
          if (request.kind != ApprovalKind.permission ||
              command is! String ||
              onCommandPattern == null ||
              !{
                ApprovalDecision.allowAlways,
                ApprovalDecision.allowWorkspace,
                ApprovalDecision.allowGlobal
              }.contains(decision)) {
            invalidPattern = true;
          } else {
            CommandApprovalPattern(commandPattern).requireMatch(command);
          }
        } on FormatException {
          invalidPattern = true;
        }
      }
      final invalidScope = (persistentGrant &&
              (request.kind != ApprovalKind.permission ||
                  !(request.details['persistent_command_approval'] == true ||
                      commandPattern != null &&
                          request.details['persistent_command_pattern'] ==
                              true))) ||
          (directoryGrant &&
              (request.kind != ApprovalKind.permission ||
                  request.details['read_directory'] is! String)) ||
          (writeGrant &&
              (request.kind != ApprovalKind.permission ||
                  request.operation != 'write' ||
                  request.details['write_directory'] is! String));
      final offers = request.details['directory_accesses'];
      final scopes = request.details['directory_grant_scopes'];
      // "Always permit reads" is only valid on the all-read ask the dialog
      // offers it on: a permission ask whose every directory offer is a
      // read. Anything else (a write ask, a confirmation, an ask whose shape
      // is unknown) cannot mean what the answer says and is denied — a
      // consumer that cannot honor standing grants then refuses loudly
      // instead of silently mis-approving. The answer's scope rides its
      // read grants (below), never a separate enum value.
      final invalidReadsAlways = decision ==
              ApprovalDecision.allowReadsAlways &&
          (request.kind != ApprovalKind.permission ||
              request.details['missing_permissions'] is List &&
                  (request.details['missing_permissions'] as List)
                      .any((permission) => permission != 'directoryAccess') ||
              request.details['required_permissions'] is List &&
                  (request.details['required_permissions'] as List).any(
                      (permission) =>
                          {'network', 'unconfined'}.contains(permission)) ||
              offers is! List ||
              offers.isEmpty ||
              offers.any((offer) =>
                  offer is! Map ||
                  offer['access'] != DirectoryAccess.read.name));
      final invalidDirectories = directoryGrants.isNotEmpty &&
          (request.kind != ApprovalKind.permission ||
              onDirectoryGrants == null ||
              !{
                ApprovalDecision.allow,
                ApprovalDecision.allowAlways,
                ApprovalDecision.allowWorkspace,
                ApprovalDecision.allowGlobal,
                // Reads-always carries the session/workspace scope on the
                // same validated grants as a plain allow.
                ApprovalDecision.allowReadsAlways
              }.contains(decision) ||
              directoryGrants.length > 32 ||
              directoryGrants.map((grant) => grant.scope).toSet().length != 1 ||
              offers is! List ||
              scopes is! List ||
              directoryGrants.any((grant) =>
                  !scopes.contains(grant.scope.name) ||
                  !offers.any((offer) =>
                      offer is Map &&
                      offer['path'] == grant.path &&
                      offer['access'] == grant.access.name)));
      if (!invalid &&
          !invalidScope &&
          !invalidPattern &&
          !invalidDirectories &&
          !invalidReadsAlways &&
          directoryGrants.isNotEmpty) {
        try {
          onDirectoryGrants!(List.unmodifiable(directoryGrants));
        } catch (_) {
          invalidPattern = true;
        }
      }
      if (!invalid &&
          !invalidDirectories &&
          !invalidReadsAlways &&
          !invalidScope &&
          !invalidPattern &&
          commandPattern != null) {
        try {
          onCommandPattern!(commandPattern);
        } catch (_) {
          invalidPattern = true;
        }
      }
      result.complete(
          invalid || invalidScope || invalidPattern || invalidDirectories ||
                  invalidReadsAlways
              ? ApprovalDecision.deny
              : request.kind == ApprovalKind.confirmation &&
                      decision == ApprovalDecision.allowAlways
                  ? ApprovalDecision.allow
                  : decision);
      return !invalid &&
          !invalidScope &&
          !invalidPattern &&
          !invalidDirectories &&
          !invalidReadsAlways;
    }, result.future);
    _pending[request.id] = ticket;
    _changed();
    final deadline = timeout;
    if (deadline != null) {
      timer = Timer(deadline, () => ticket.respond(ApprovalDecision.deny));
    }
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
    _observers.clear();
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

  bool respond(String id, ApprovalDecision decision,
          {String? commandPattern,
          List<DirectoryAccessGrant> directoryGrants = const []}) =>
      _pending[id]?.respond(decision,
          commandPattern: commandPattern, directoryGrants: directoryGrants) ??
      false;
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
