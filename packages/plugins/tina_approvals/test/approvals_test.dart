import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

final class CapturingChannel implements ApprovalChannel {
  final tickets = <ApprovalTicket>[];
  @override
  Future<void> deliver(ApprovalTicket ticket) async {
    tickets.add(ticket);
  }
}

final class BrokenChannel implements ApprovalChannel {
  @override
  Future<void> deliver(ApprovalTicket ticket) async {
    throw StateError('transport disconnected');
  }
}

Future<ApprovalDecision> ask(ApprovalRequester service,
        [String target = '/outside']) =>
    service.request(
        operation: 'write', target: target, reason: 'outside workspace');
TurnContext context(CancelToken token) => TurnContext(token,
    input: Input('test', id: 'turn'),
    messages: [],
    promptSections: [],
    pinnedTools: []);

void main() {
  test('write scope requires a write request offering that directory',
      () async {
    final channel = CapturingChannel();
    final service = ApprovalsPlugin(channel: channel);
    addTearDown(service.closeSession);
    for (final decision in [
      ApprovalDecision.allowWritesInDirectory,
      ApprovalDecision.allowAlwaysAndWritesInDirectory
    ]) {
      for (final kind in ApprovalKind.values) {
        for (final op in ['write', 'run command']) {
          for (final offered in [true, false]) {
            final pending = service.request(
                operation: op,
                target: '/external/file',
                reason: 'ask',
                kind: kind,
                details: {if (offered) 'write_directory': '/external'});
            await Future<void>.delayed(Duration.zero);
            final valid =
                offered && op == 'write' && kind == ApprovalKind.permission;
            expect(channel.tickets.last.respond(decision), valid);
            expect(await pending, valid ? decision : ApprovalDecision.deny);
          }
        }
      }
    }
  });
  test('read directory grants must have been offered by the requester',
      () async {
    final channel = CapturingChannel();
    final service = ApprovalsPlugin(channel: channel);
    addTearDown(service.closeSession);
    final absent = ask(service);
    await Future<void>.delayed(Duration.zero);
    expect(channel.tickets.last.respond(ApprovalDecision.allowReadsInDirectory),
        isFalse);
    expect(await absent, ApprovalDecision.deny);
    final offered = service.request(
        operation: 'run command',
        target: 'grep',
        reason: 'read external directory',
        details: {'read_directory': '/external'});
    await Future<void>.delayed(Duration.zero);
    expect(channel.tickets.last.respond(ApprovalDecision.allowReadsInDirectory),
        isTrue);
    expect(await offered, ApprovalDecision.allowReadsInDirectory);
  });
  test('default approval schedules no expiry and accepts a later answer',
      () async {
    final channel = CapturingChannel();
    final service = ApprovalsPlugin(channel: channel);
    addTearDown(service.closeSession);
    var timers = 0;
    final pending = runZoned(() => ask(service), zoneSpecification:
        ZoneSpecification(
            createTimer: (self, parent, zone, duration, callback) {
      timers++;
      return parent.createTimer(zone, duration, callback);
    }));
    expect(service.timeout, isNull);
    expect(timers, 0);
    await Future<void>.delayed(Duration.zero);
    expect(service.pending, hasLength(1));
    expect(channel.tickets.single.isActive, isTrue);
    channel.tickets.single.respond(ApprovalDecision.allow);
    expect(await pending, ApprovalDecision.allow);
  });

  test('correlates concurrent responses and rejects unknown/duplicate IDs',
      () async {
    final channel = StreamApprovalChannel();
    final requests = <ApprovalRequest>[];
    final sub = channel.requests.listen(requests.add);
    final service = ApprovalsPlugin(channel: channel);
    addTearDown(() async {
      service.closeSession();
      channel.closeSession();
      await sub.cancel();
    });
    final first = ask(service, '/one');
    final second = ask(service, '/two');
    await Future<void>.delayed(Duration.zero);
    expect(requests.map((r) => r.target), ['/one', '/two']);
    expect(requests.map((r) => r.id).toSet(), hasLength(2));
    expect(channel.respond('missing', ApprovalDecision.allow), false);
    expect(channel.respond(requests[1].id, ApprovalDecision.deny), true);
    expect(channel.respond(requests[0].id, ApprovalDecision.allow), true);
    expect(
        channel.respond(requests[0].id, ApprovalDecision.allowAlways), false);
    expect(await first, ApprovalDecision.allow);
    expect(await second, ApprovalDecision.deny);
    expect(service.pending, isEmpty);
  });

  test('a disconnected or failed channel denies instead of hanging', () async {
    final stream = StreamApprovalChannel();
    final absent = ApprovalsPlugin(channel: stream);
    final broken = ApprovalsPlugin(channel: BrokenChannel());
    addTearDown(() {
      absent.closeSession();
      broken.closeSession();
      stream.closeSession();
    });
    expect(await ask(absent), ApprovalDecision.deny);
    expect(await ask(broken), ApprovalDecision.deny);
  });

  test('channel disconnect denies pending requests and prevents late responses',
      () async {
    final stream = StreamApprovalChannel();
    final requests = <ApprovalRequest>[];
    final subscription = stream.requests.listen(requests.add);
    final service = ApprovalsPlugin(channel: stream);
    addTearDown(() {
      service.closeSession();
      stream.closeSession();
    });
    final pending = ask(service);
    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();
    expect(await pending, ApprovalDecision.deny);
    expect(stream.respond(requests.single.id, ApprovalDecision.allow), false);
  });

  test('timeout and shutdown invalidate requests and release waiters',
      () async {
    final channel = CapturingChannel();
    final service = ApprovalsPlugin(
        channel: channel, timeout: const Duration(milliseconds: 10));
    expect(await ask(service), ApprovalDecision.deny);
    expect(channel.tickets.single.isActive, false);
    expect(channel.tickets.single.respond(ApprovalDecision.allow), false);
    final next = ask(service);
    service.closeSession();
    expect(await next, ApprovalDecision.deny);
    expect(await ask(service), ApprovalDecision.deny);
    expect(service.pending, isEmpty);
  });

  test('turn cancellation invalidates responses synchronously, next turn works',
      () async {
    final channel = CapturingChannel();
    final service = ApprovalsPlugin(channel: channel);
    addTearDown(service.closeSession);
    final token = CancelToken();
    final turn = context(token);
    service.onInput(turn);
    final pending = ask(service);
    await Future<void>.delayed(Duration.zero);
    token.cancel('escape');
    // The callback cannot win even before the cancellation future is delivered.
    expect(channel.tickets.single.respond(ApprovalDecision.allow), false);
    expect(await pending, ApprovalDecision.deny);
    expect(await ask(service), ApprovalDecision.deny);
    service.onTurnEnd(turn);
    service.onInput(context(CancelToken()));
    final next = ask(service);
    await Future<void>.delayed(Duration.zero);
    expect(channel.tickets.last.respond(ApprovalDecision.allow), true);
    expect(await next, ApprovalDecision.allow);
  });

  test(
      'cancellation releases an unanswered request without channel cooperation',
      () async {
    final channel = CapturingChannel();
    final service = ApprovalsPlugin(channel: channel);
    addTearDown(service.closeSession);
    final token = CancelToken();
    service.onInput(context(token));
    final pending = ask(service);
    token.cancel('stop');
    expect(await pending, ApprovalDecision.deny);
    expect(channel.tickets.single.isActive, false);
  });
}
