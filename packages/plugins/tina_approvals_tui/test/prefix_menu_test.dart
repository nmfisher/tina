import 'package:test/test.dart';
import 'package:tina_approvals_tui/tina_approvals_tui.dart';
import 'package:tina_console/tina_console.dart';

String _text(RenderLine row) => row.runs.map((r) => r.text).join();
ApprovalDialog _dialog({bool persistent = true, bool confirmation = false}) =>
    ApprovalDialog(null,
        ask: ApprovalAskContext('run command', 'gh pr view 429', 'Inspect PR',
            confirmation: confirmation,
            details: {
              'permission_scope': 'command',
              'resource_permissions': true,
              'command_prefixes': ['gh pr view'],
              'persistent_command_prefix': persistent,
              'persistent_command_approval': true,
            }));

void main() {
  test('prefix scopes are visible immediately and Run once is the default', () {
    final dialog = _dialog();
    final shown = dialog.rows(width: 140).map(_text).join('\n');
    expect(shown, contains('❯ [y] Run once'));
    expect(shown, contains('[a] Remember for this conversation: gh pr view'));
    expect(shown, contains('[p] Persist for this workspace: gh pr view'));
    expect(shown, contains('[n] deny'));
    expect(dialog.current.decision, ApprovalDecision.allow);
  });
  test('arrows and shortcuts select the same explicit prefix scope', () async {
    for (final choice in [
      (ApprovalKey.always, ApprovalDecision.allowPrefixInSession, 1),
      (ApprovalKey.workspace, ApprovalDecision.allowPrefixInWorkspace, 2),
    ]) {
      final shortcut =
          await _dialog().awaitDecision(ScriptedKeySource([choice.$1]));
      final arrows = await _dialog().awaitDecision(ScriptedKeySource([
        for (var i = 0; i < choice.$3; i++) ApprovalKey.down,
        ApprovalKey.confirm,
      ]));
      expect(shortcut.decision, choice.$2);
      expect(arrows.decision, choice.$2);
      expect(shortcut.directoryGrants, isEmpty);
      expect(shortcut.editCommandPattern, false);
    }
  });
  test(
      'persistence is hidden without storage; confirmation has Yes and No only',
      () async {
    expect(_dialog(persistent: false).rows().map(_text).join(),
        isNot(contains('Persist')));
    expect(
        (await _dialog(persistent: false).awaitDecision(
                ScriptedKeySource([ApprovalKey.workspace, ApprovalKey.deny])))
            .decision,
        ApprovalDecision.deny);
    final confirmation = _dialog(confirmation: true).rows().map(_text).join();
    expect(confirmation, isNot(contains('Remember')));
    expect(confirmation, isNot(contains('Persist')));
  });
}
