import 'package:test/test.dart';
import 'package:tina_approvals_tui/tina_approvals_tui.dart';

void main() {
  ApprovalDialog persistentDialog() => ApprovalDialog(null,
      ask: const ApprovalAskContext(
          'run command', 'git push origin main', 'host SSH identity',
          details: {'persistent_command_approval': true}));

  test('persistent scopes appear only after Remember', () {
    final dialog = persistentDialog()..handleKey(ApprovalKey.always);
    final rows = dialog
        .rows(width: 100, height: 30)
        .map((r) => r.runs.map((run) => run.text).join())
        .join('\n');
    expect(rows, contains('[p] Save this access for this workspace'));
    expect(rows, contains('[g] Save this access globally'));
    expect(rows, isNot(contains('always allow…')));
  });

  test('a opens the session scope and Enter confirms', () async {
    final dialog = persistentDialog();
    final outcome = await dialog.awaitDecision(
        ScriptedKeySource([ApprovalKey.always, ApprovalKey.confirm]));
    expect(outcome.decision, ApprovalDecision.allowAlways);
  });

  test('p selects workspace after Remember', () async {
    final dialog = persistentDialog();
    final outcome = await dialog.awaitDecision(
        ScriptedKeySource([ApprovalKey.always, ApprovalKey.workspace]));
    expect(outcome.decision, ApprovalDecision.allowWorkspace);
  });

  test('g selects global after Remember', () async {
    final dialog = persistentDialog();
    final outcome = await dialog.awaitDecision(
        ScriptedKeySource([ApprovalKey.always, ApprovalKey.global]));
    expect(outcome.decision, ApprovalDecision.allowGlobal);
  });

  test('arrows move the remembered scope rows and Enter confirms', () async {
    final dialog = persistentDialog();
    final outcome = await dialog.awaitDecision(ScriptedKeySource([
      ApprovalKey.always,
      ApprovalKey.down,
      ApprovalKey.down, // allow global
      ApprovalKey.confirm
    ]));
    expect(outcome.decision, ApprovalDecision.allowGlobal);
  });

  test('without persistent scopes a keeps the single-session meaning',
      () async {
    final dialog = ApprovalDialog(null,
        ask: const ApprovalAskContext('write', '/project/file', 'write file'));
    final outcome = await dialog.awaitDecision(
        ScriptedKeySource([ApprovalKey.always, ApprovalKey.confirm]));
    expect(outcome.decision, ApprovalDecision.allowAlways);
  });

  test('p and g are rejected without persistent command-scope support',
      () async {
    final dialog = ApprovalDialog(null,
        ask: const ApprovalAskContext('write', '/project/file', 'write file'));
    final outcome = await dialog.awaitDecision(ScriptedKeySource(
        [ApprovalKey.workspace, ApprovalKey.global, ApprovalKey.cancel]));
    expect(outcome.decision, ApprovalDecision.deny);
    expect(outcome.reason, 'cancelled');
  });
}
