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
  test('directory responses require an offered path, access and explicit scope',
      () async {
    for (final grant in [
      const DirectoryAccessGrant(
          '/other', DirectoryAccess.read, DirectoryGrantScope.workspace),
      const DirectoryAccessGrant(
          '/other', DirectoryAccess.write, DirectoryGrantScope.workspace),
      const DirectoryAccessGrant(
          '/unoffered', DirectoryAccess.read, DirectoryGrantScope.workspace),
      const DirectoryAccessGrant(
          '/other', DirectoryAccess.read, DirectoryGrantScope.global),
    ]) {
      final channel = CapturingChannel();
      final service = ApprovalsPlugin(channel: channel);
      addTearDown(service.closeSession);
      List<DirectoryAccessGrant>? received;
      final pending = service.request(
          operation: 'run command',
          target: 'grep',
          reason: 'read',
          details: {
            'directory_accesses': [
              {'path': '/other', 'access': 'read'}
            ],
            'directory_grant_scopes': ['workspace']
          },
          onDirectoryGrants: (grants) => received = grants);
      await Future<void>.delayed(Duration.zero);
      final valid = grant.path == '/other' &&
          grant.access == DirectoryAccess.read &&
          grant.scope == DirectoryGrantScope.workspace;
      expect(
          channel.tickets.single
              .respond(ApprovalDecision.allow, directoryGrants: [grant]),
          valid);
      expect(await pending,
          valid ? ApprovalDecision.allow : ApprovalDecision.deny);
      expect(received, valid ? [grant] : null);
    }
  });

  test('denied and cancelled responses never deliver directory grants',
      () async {
    for (final cancelled in [false, true]) {
      final channel = CapturingChannel();
      final service = ApprovalsPlugin(channel: channel);
      addTearDown(service.closeSession);
      final token = CancelToken();
      service.onInput(context(token));
      final pending = service.request(
          operation: 'read',
          target: '/other',
          reason: 'read',
          details: {
            'directory_accesses': [
              {'path': '/other', 'access': 'read'}
            ],
            'directory_grant_scopes': ['workspace']
          },
          onDirectoryGrants: (_) =>
              fail('No grant after denial or cancellation'));
      await Future<void>.delayed(Duration.zero);
      if (cancelled) token.cancel('cancel');
      channel.tickets.single.respond(
          cancelled ? ApprovalDecision.allow : ApprovalDecision.deny,
          directoryGrants: [
            const DirectoryAccessGrant(
                '/other', DirectoryAccess.read, DirectoryGrantScope.workspace)
          ]);
      expect(await pending, ApprovalDecision.deny);
    }
  });
  test(
      'regex responses require a matching offered command and remembered scope',
      () async {
    for (final pattern in [r'head -n[0-9]+', '[', 'head', '.*\n']) {
      for (final offered in [false, true]) {
        for (final decision in [
          ApprovalDecision.allow,
          ApprovalDecision.allowAlways,
          ApprovalDecision.allowWorkspace,
          ApprovalDecision.allowGlobal
        ]) {
          final channel = CapturingChannel();
          final service = ApprovalsPlugin(channel: channel);
          addTearDown(service.closeSession);
          String? received;
          final pending = service.request(
              operation: 'run command',
              target: 'head -n2',
              reason: 'execute',
              details: {
                if (offered) 'command_pattern_target': 'head -n2',
                'persistent_command_pattern': true,
              },
              onCommandPattern: (value) => received = value);
          await Future<void>.delayed(Duration.zero);
          final valid = offered &&
              pattern == r'head -n[0-9]+' &&
              decision != ApprovalDecision.allow;
          expect(
              channel.tickets.single.respond(decision, commandPattern: pattern),
              valid,
              reason: 'pattern=$pattern offered=$offered decision=$decision');
          expect(await pending, valid ? decision : ApprovalDecision.deny);
          expect(received, valid ? pattern : null);
        }
      }
    }
  });
  test(
      'strict whole-command matching rejects alternative prefixes and final newlines',
      () {
    final pattern = CommandApprovalPattern(r'head -n[0-9]+|tail -n[0-9]+');
    expect(pattern.matches('head -n20'), true);
    expect(pattern.matches('tail -n20'), true);
    for (final denied in ['head -n2; echo extra', 'head -n2\n', 'xhead -n2']) {
      expect(pattern.matches(denied), false);
    }
  });
  test('cancelled command regex response cannot call back or approve',
      () async {
    final channel = CapturingChannel();
    final service = ApprovalsPlugin(channel: channel);
    final pending = service.request(
        operation: 'run command',
        target: 'head -n2',
        reason: 'execute',
        details: {'command_pattern_target': 'head -n2'},
        onCommandPattern: (_) => fail('cancelled callback'));
    await Future<void>.delayed(Duration.zero);
    service.closeSession();
    expect(await pending, ApprovalDecision.deny);
    expect(
        channel.tickets.single.respond(ApprovalDecision.allowAlways,
            commandPattern: r'head -n[0-9]+'),
        false);
  });
  test('regex storage scope, confirmations and callback support fail closed',
      () async {
    for (final kind in ApprovalKind.values) {
      for (final persistent in [false, true]) {
        for (final callback in [false, true]) {
          final channel = CapturingChannel();
          final service = ApprovalsPlugin(channel: channel);
          addTearDown(service.closeSession);
          final pending = service.request(
              operation: 'run command',
              target: 'head -n2',
              reason: 'execute',
              kind: kind,
              details: {
                'command_pattern_target': 'head -n2',
                if (persistent) 'persistent_command_pattern': true,
              },
              onCommandPattern: callback ? (_) {} : null);
          await Future<void>.delayed(Duration.zero);
          final valid =
              kind == ApprovalKind.permission && persistent && callback;
          expect(
              channel.tickets.single.respond(ApprovalDecision.allowGlobal,
                  commandPattern: r'head -n[0-9]+'),
              valid);
          expect(await pending,
              valid ? ApprovalDecision.allowGlobal : ApprovalDecision.deny);
        }
      }
    }
  });
  test('persistent command scopes require an explicitly offered permission',
      () async {
    for (final decision in [
      ApprovalDecision.allowWorkspace,
      ApprovalDecision.allowGlobal
    ]) {
      for (final offered in [false, true]) {
        final channel = CapturingChannel();
        final service = ApprovalsPlugin(channel: channel);
        addTearDown(service.closeSession);
        final pending = service.request(
            operation: 'run command',
            target: 'ssh host',
            reason: 'host authentication',
            details: {
              if (offered) 'persistent_command_approval': true,
            });
        await Future<void>.delayed(Duration.zero);
        expect(channel.tickets.single.respond(decision), offered);
        expect(await pending, offered ? decision : ApprovalDecision.deny);
      }
    }
  });
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
  test('always-permit-reads answers require the all-read permission shape',
      () async {
    final allRead = {
      'directory_accesses': [
        {'path': '/other', 'access': 'read'}
      ],
      'directory_grant_scopes': ['session', 'workspace'],
    };
    final mixed = {
      'directory_accesses': [
        {'path': '/other', 'access': 'read'},
        {'path': '/output', 'access': 'write'},
      ],
      'directory_grant_scopes': ['session'],
    };
    for (final entry in [
      (details: allRead, kind: ApprovalKind.permission, valid: true),
      // No directory offers at all cannot carry a standing grant.
      (details: <String, Object?>{}, kind: ApprovalKind.permission,
          valid: false),
      // A write among the offers disqualifies the standing reads grant.
      (details: mixed, kind: ApprovalKind.permission, valid: false),
      // Confirmations are yes/no; standing grants never ride them.
      (details: allRead, kind: ApprovalKind.confirmation, valid: false),
    ]) {
      final channel = CapturingChannel();
      final service = ApprovalsPlugin(channel: channel);
      addTearDown(service.closeSession);
      List<DirectoryAccessGrant>? received;
      final pending = service.request(
          operation: 'run command',
          target: 'grep -r x /other',
          reason: 'read',
          kind: entry.kind,
          details: entry.details,
          onDirectoryGrants: (grants) => received = grants);
      await Future<void>.delayed(Duration.zero);
      final ticket = channel.tickets.single;
      if (entry.valid) {
        // The session/workspace scope rides the answer's validated read
        // grants, exactly like a plain allow.
        expect(
            ticket.respond(ApprovalDecision.allowReadsAlways,
                directoryGrants: [
                  const DirectoryAccessGrant('/other', DirectoryAccess.read,
                      DirectoryGrantScope.workspace)
                ]),
            isTrue);
        expect(await pending, ApprovalDecision.allowReadsAlways);
        expect(received, hasLength(1));
        // A bare answer (no grants) stays valid: consumers that cannot
        // honor standing grants decide for themselves.
        final bare = CapturingChannel();
        final bareService = ApprovalsPlugin(channel: bare);
        addTearDown(bareService.closeSession);
        final barePending = bareService.request(
            operation: 'run command',
            target: 'grep -r x /other',
            reason: 'read',
            details: entry.details);
        await Future<void>.delayed(Duration.zero);
        expect(bare.tickets.single.respond(ApprovalDecision.allowReadsAlways),
            isTrue);
        expect(await barePending, ApprovalDecision.allowReadsAlways);
      } else {
        expect(
            ticket.respond(ApprovalDecision.allowReadsAlways,
                directoryGrants: [
                  const DirectoryAccessGrant('/other', DirectoryAccess.read,
                      DirectoryGrantScope.workspace)
                ]),
            isFalse,
            reason: '${entry.details} / ${entry.kind}');
        expect(await pending, ApprovalDecision.deny);
        expect(received, isNull);
      }
    }
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
