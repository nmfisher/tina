import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_mode/tina_mode.dart';

void main() {
  for (final mode in PermissionMode.values) {
    test(
      '$mode freely resolves workspace reads and confined read-only execution',
      () {
        final request = AuthorizationRequest(
          readOnlyExecution: true,
          confined: true,
          requirements: const [
            AccessRequirement(
              AccessCapability.read,
              '/workspace/input',
              workspace: true,
            ),
            AccessRequirement(
              AccessCapability.execute,
              'arbitrary script',
              workspace: true,
            ),
          ],
        );
        expect(
          resolveAuthorization(request, mode).route,
          AuthorizationRoute.allow,
        );
      },
    );
    test('$mode resolves all missing permissions together', () {
      final request = AuthorizationRequest(
        confined: true,
        requirements: const [
          AccessRequirement(AccessCapability.read, '/external'),
          AccessRequirement(AccessCapability.network, 'service'),
        ],
      );
      expect(
        resolveAuthorization(request, mode).route,
        mode == PermissionMode.yolo
            ? AuthorizationRoute.allow
            : AuthorizationRoute.human,
      );
    });
    test('$mode confirmations require an explicit human answer', () {
      expect(
        resolveAuthorization(
          AuthorizationRequest(requirements: const []),
          mode,
          kind: ApprovalKind.confirmation,
        ).route,
        AuthorizationRoute.human,
      );
    });
  }
  test('read-only mode ceiling precedes every remembered write grant', () {
    for (final capability in [
      AccessCapability.write,
      AccessCapability.host,
      AccessCapability.external,
    ]) {
      final request = AuthorizationRequest(
        requirements: [
          AccessRequirement(
            capability,
            '/target',
            workspace: true,
            granted: true,
          ),
        ],
      );
      expect(
        resolveAuthorization(request, PermissionMode.readOnly).route,
        AuthorizationRoute.deny,
      );
    }
  });
  test('workspace mutations follow the mode matrix', () {
    final request = AuthorizationRequest(
      confined: true,
      requirements: const [
        AccessRequirement(
          AccessCapability.write,
          '/workspace/file',
          workspace: true,
        ),
        AccessRequirement(AccessCapability.execute, 'script', workspace: true),
      ],
    );
    for (final entry in {
      PermissionMode.readOnly: AuthorizationRoute.deny,
      PermissionMode.ask: AuthorizationRoute.human,
      PermissionMode.allowEdits: AuthorizationRoute.allow,
      PermissionMode.auto: AuthorizationRoute.review,
      PermissionMode.yolo: AuthorizationRoute.allow,
    }.entries) {
      expect(resolveAuthorization(request, entry.key).route, entry.value);
    }
  });
  test('read-only execution fails closed when confinement is unavailable', () {
    final request = AuthorizationRequest(
      readOnlyExecution: true,
      requirements: const [
        AccessRequirement(AccessCapability.execute, 'script', workspace: true),
      ],
    );
    expect(
      resolveAuthorization(request, PermissionMode.readOnly).route,
      AuthorizationRoute.deny,
    );
  });
  test('mode changes dismiss and re-evaluate pending human requests', () async {
    final channel = StreamApprovalChannel();
    final approvals = ApprovalsPlugin(channel: channel);
    final policy = ModePlugin(approvals: approvals);
    final requests = <ApprovalRequest>[];
    final subscription = channel.requests.listen(requests.add);
    addTearDown(() async {
      policy.closeSession();
      approvals.closeSession();
      await subscription.cancel();
    });
    final result = policy.request(
      operation: 'write',
      target: '/workspace/file',
      reason: 'write',
      authorization: AuthorizationRequest(
        requirements: const [
          AccessRequirement(
            AccessCapability.write,
            '/workspace/file',
            workspace: true,
          ),
        ],
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(requests, hasLength(1));
    policy.mode = PermissionMode.readOnly;
    expect(await result, ApprovalDecision.deny);
    expect(approvals.pending, isEmpty);
    expect(channel.respond(requests.single.id, ApprovalDecision.allow), false);
  });
  test('running child policies follow the live parent mode', () {
    final parent = ModePlugin(mode: PermissionMode.allowEdits);
    final child = ModePlugin()..inheritPolicy(parent);
    parent.mode = PermissionMode.readOnly;
    expect(child.mode, PermissionMode.readOnly);
    child.closeSession();
    parent.mode = PermissionMode.auto;
    parent.closeSession();
  });
}
