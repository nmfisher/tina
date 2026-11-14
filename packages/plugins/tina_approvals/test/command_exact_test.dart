import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';

void main() {
  for (final decision in [
    ApprovalDecision.allowExactInSession,
    ApprovalDecision.allowExactInWorkspace
  ]) {
    test('$decision requires a command offer, scope and storage', () async {
      for (final mode in [
        'valid',
        'missing',
        'file',
        'confirmation',
        'no storage'
      ]) {
        final channel = StreamApprovalChannel();
        final plugin = ApprovalsPlugin(channel: channel);
        final subscription =
            channel.requests.listen((ask) => channel.respond(ask.id, decision));
        final result = await plugin.request(
            operation: 'run command',
            target: 'node script.cjs',
            reason: 'QA',
            kind: mode == 'confirmation'
                ? ApprovalKind.confirmation
                : ApprovalKind.permission,
            details: {
              'permission_scope': mode == 'file' ? 'file' : 'command',
              'exact_command_approval': mode != 'missing',
              'persistent_exact_command': mode != 'no storage',
            });
        final valid = mode == 'valid' ||
            mode == 'no storage' &&
                decision == ApprovalDecision.allowExactInSession;
        expect(result, valid ? decision : ApprovalDecision.deny, reason: mode);
        await subscription.cancel();
        plugin.closeSession();
        channel.closeSession();
      }
    });
  }
}
