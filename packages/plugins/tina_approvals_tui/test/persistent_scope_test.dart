import 'package:test/test.dart';
import 'package:tina_approvals_tui/tina_approvals_tui.dart';

void main() {
  ApprovalDialog persistentDialog() => ApprovalDialog(null,
      ask: const ApprovalAskContext('run command', 'git push origin main',
          'host SSH identity',
          details: {'persistent_command_approval': true}));

  test('persistent scopes are rows on the first menu', () {
    final dialog = persistentDialog();
    final rows = dialog.rows(width: 100, height: 30).map((r) => r.runs.map((run) => run.text).join()).join('\n');
    expect(rows, contains('[p] remember this command for this workspace'));
    expect(rows, contains('[g] remember this command globally (any directory)'));
    expect(rows, isNot(contains('always allow…')));
  });

  test('a decides the session scope immediately', () async {
    final dialog = persistentDialog();
    final outcome =
        await dialog.awaitDecision(ScriptedKeySource([ApprovalKey.always]));
    expect(outcome.decision, ApprovalDecision.allowAlways);
  });

  test('p decides the workspace scope immediately', () async {
    final dialog = persistentDialog();
    final outcome =
        await dialog.awaitDecision(ScriptedKeySource([ApprovalKey.workspace]));
    expect(outcome.decision, ApprovalDecision.allowWorkspace);
  });

  test('g decides the global scope immediately', () async {
    final dialog = persistentDialog();
    final outcome =
        await dialog.awaitDecision(ScriptedKeySource([ApprovalKey.global]));
    expect(outcome.decision, ApprovalDecision.allowGlobal);
  });

  test('arrows move the flat scope rows and Enter confirms', () async {
    final dialog = persistentDialog();
    final outcome = await dialog.awaitDecision(ScriptedKeySource([
      ApprovalKey.down,
      ApprovalKey.down,
      ApprovalKey.down,
      ApprovalKey.down, // allow global
      ApprovalKey.confirm
    ]));
    expect(outcome.decision, ApprovalDecision.allowGlobal);
  });

  test('without persistent scopes a keeps the single-session meaning',
      () async {
    final dialog = ApprovalDialog(null,
        ask: const ApprovalAskContext(
            'write', '/project/file', 'write file'));
    final outcome =
        await dialog.awaitDecision(ScriptedKeySource([ApprovalKey.always]));
    expect(outcome.decision, ApprovalDecision.allowAlways);
  });

  test('p and g are rejected without persistent command-scope support',
      () async {
    final dialog = ApprovalDialog(null,
        ask: const ApprovalAskContext(
            'write', '/project/file', 'write file'));
    final outcome = await dialog.awaitDecision(
        ScriptedKeySource([ApprovalKey.workspace, ApprovalKey.global, ApprovalKey.cancel]));
    expect(outcome.decision, ApprovalDecision.deny);
    expect(outcome.reason, 'cancelled');
  });
}
