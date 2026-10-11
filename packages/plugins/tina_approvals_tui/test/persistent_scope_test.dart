import 'package:test/test.dart';
import 'package:tina_approvals_tui/tina_approvals_tui.dart';

void main() {
  test('workspace and global choices require explicit command-scope support',
      () async {
    for (final key in [ApprovalKey.workspace, ApprovalKey.global]) {
      final dialog = ApprovalDialog(null,
          ask: const ApprovalAskContext(
              'run command', 'git push origin main', 'host SSH identity',
              details: {'persistent_command_approval': true}));
      final result = await dialog.awaitDecision(ScriptedKeySource([key]));
      expect(
          result.decision,
          key == ApprovalKey.workspace
              ? ApprovalDecision.allowWorkspace
              : ApprovalDecision.allowGlobal);
      final ordinary = ApprovalDialog(null,
          ask:
              const ApprovalAskContext('write', '/project/file', 'write file'));
      final rejected = await ordinary
          .awaitDecision(ScriptedKeySource([key, ApprovalKey.cancel]));
      expect(rejected.decision, ApprovalDecision.deny);
    }
  });
}
