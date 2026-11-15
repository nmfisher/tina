import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';

void main() {
  for (final decision in [
    ApprovalDecision.allowPrefixInSession,
    ApprovalDecision.allowPrefixInWorkspace
  ]) {
    test('$decision requires an explicit command-prefix offer and valid scope',
        () async {
      for (final mode in [
        'valid',
        'missing',
        'file',
        'confirmation',
        'empty',
        'no storage'
      ]) {
        final channel = StreamApprovalChannel();
        final plugin = ApprovalsPlugin(channel: channel);
        final subscription = channel.requests.listen((ask) {
          channel.respond(ask.id, decision);
        });
        final answer = await plugin.request(
            operation: 'run command',
            target: 'gh pr view 429',
            reason: 'Inspect requested PR',
            kind: mode == 'confirmation'
                ? ApprovalKind.confirmation
                : ApprovalKind.permission,
            details: {
              'permission_scope': mode == 'file' ? 'file' : 'command',
              if (mode != 'missing')
                'command_prefixes': mode == 'empty' ? [] : ['gh pr view'],
              'persistent_command_approval': true,
              'persistent_command_prefix': mode != 'no storage',
            });
        final valid = mode == 'valid' ||
            mode == 'no storage' &&
                decision == ApprovalDecision.allowPrefixInSession;
        expect(answer, valid ? decision : ApprovalDecision.deny, reason: mode);
        await subscription.cancel();
        plugin.closeSession();
        channel.closeSession();
      }
    });
  }
}
