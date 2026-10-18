import 'package:test/test.dart';
import 'package:tina_approvals_tui/tina_approvals_tui.dart';

void main() {
  ApprovalDialog persistentDialog() => ApprovalDialog(null,
      ask: const ApprovalAskContext('run command', 'git push origin main',
          'host SSH identity',
          details: {'persistent_command_approval': true}));

  test('persistent offers collapse into one always-allow submenu row', () {
    final dialog = persistentDialog();
    final rows = dialog.rows(width: 100, height: 30).map((r) => r.runs.map((run) => run.text).join()).join('\n');
    expect(rows, contains('[a] always allow…'));
    expect(rows, isNot(contains('remember this command for this workspace')));
    expect(rows, isNot(contains('remember this command globally')));
  });

  test('the submenu lists session, workspace and global scopes', () {
    final dialog = persistentDialog();
    dialog.openScopeMenu(ApprovalKey.always);
    final rows = dialog.rows(width: 100, height: 30).map((r) => r.runs.map((run) => run.text).join()).join('\n');
    expect(rows, contains('for this session'));
    expect(rows, contains('remember for this workspace'));
    expect(rows, contains('remember globally (any directory)'));
    expect(rows, contains('Esc back'));
  });

  test('a opens the submenu; enter confirms the session scope', () async {
    final dialog = persistentDialog();
    final outcome = await dialog
        .awaitDecision(ScriptedKeySource([ApprovalKey.always, ApprovalKey.confirm]));
    expect(outcome.decision, ApprovalDecision.allowAlways);
  });

  test('p jumps into the submenu on workspace and enter confirms', () async {
    final dialog = persistentDialog();
    final outcome = await dialog.awaitDecision(
        ScriptedKeySource([ApprovalKey.workspace, ApprovalKey.confirm]));
    expect(outcome.decision, ApprovalDecision.allowWorkspace);
  });

  test('g jumps into the submenu on global and enter confirms', () async {
    final dialog = persistentDialog();
    final outcome = await dialog
        .awaitDecision(ScriptedKeySource([ApprovalKey.global, ApprovalKey.confirm]));
    expect(outcome.decision, ApprovalDecision.allowGlobal);
  });

  test('arrows move the submenu selection', () async {
    final dialog = persistentDialog();
    final outcome = await dialog.awaitDecision(ScriptedKeySource([
      ApprovalKey.always,
      ApprovalKey.down,
      ApprovalKey.down,
      ApprovalKey.confirm
    ]));
    expect(outcome.decision, ApprovalDecision.allowGlobal);
  });

  test('esc backs out of the submenu without deciding; then denies',
      () async {
    final dialog = persistentDialog();
    final outcome = await dialog.awaitDecision(
        ScriptedKeySource([ApprovalKey.always, ApprovalKey.cancel, ApprovalKey.deny]));
    expect(outcome.decision, ApprovalDecision.deny);
    expect(outcome.reason, isNull);
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
