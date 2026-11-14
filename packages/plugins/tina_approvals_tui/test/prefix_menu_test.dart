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
  ApprovalDialog exact({bool persistent = true, bool file = false}) =>
      ApprovalDialog(null,
          ask: ApprovalAskContext(
              'run command', 'node scripts/qa.cjs', 'Run QA',
              details: {
                'permission_scope': file ? 'file' : 'command',
                'resource_permissions': true,
                'exact_command_approval': true,
                'persistent_exact_command': persistent,
                'persistent_command_approval': true,
                'directory_accesses': [
                  {'path': '/opt/homebrew', 'access': 'read', 'granted': true}
                ],
              }));
  test(
      'exact command choices are explicit and do not offer redundant Homebrew reads',
      () async {
    final shown = exact().rows(width: 160).map(_text).join('\n');
    expect(shown,
        contains('[e] Always allow this exact command for this session'));
    expect(shown,
        contains('[w] Always allow this exact command for this workspace'));
    expect(shown, isNot(contains('Remember…')));
    expect(
        shown, isNot(contains('Session approval covers this exact command')));
    expect(shown, isNot(contains('conversation')));
    expect(
        (await exact().awaitDecision(
                ScriptedKeySource([ApprovalKey.editCommandPattern])))
            .decision,
        ApprovalDecision.allowExactInSession);
    expect(
        (await exact().awaitDecision(
                ScriptedKeySource([ApprovalKey.toggleWriteDirectory])))
            .decision,
        ApprovalDecision.allowExactInWorkspace);
    expect(
        (await exact().awaitDecision(
                ScriptedKeySource([ApprovalKey.down, ApprovalKey.confirm])))
            .decision,
        ApprovalDecision.allowExactInSession);
    expect(
        (await exact().awaitDecision(ScriptedKeySource(
                [ApprovalKey.down, ApprovalKey.down, ApprovalKey.confirm])))
            .decision,
        ApprovalDecision.allowExactInWorkspace);
    expect(exact(persistent: false).rows(width: 160).map(_text).join(),
        isNot(contains('[w]')));
    expect(exact(file: true).rows(width: 160).map(_text).join(),
        isNot(contains('Always allow this exact command')));
    expect(
        (await exact(persistent: false).awaitDecision(ScriptedKeySource(
                [ApprovalKey.toggleWriteDirectory, ApprovalKey.deny])))
            .decision,
        ApprovalDecision.deny);
  });

  test('unavailable prefixes explain why in the normal approval prompt', () {
    final dialog = ApprovalDialog(null,
        ask: ApprovalAskContext('run command', 'cd sub; head file', 'Inspect',
            details: {
              'permission_scope': 'command',
              'command_prefix_unavailable_reason':
                  'State-changing builtins require invocation review.',
            }));
    final shown = dialog.rows(width: 160).map(_text).join('\n');
    expect(shown, contains('Prefix approval unavailable: State-changing builtins'));
    expect(shown, isNot(contains('Remember for this conversation')));
    expect(shown, contains('[y] allow once'));
    expect(shown, contains('[n] deny'));
  });

  test('prefix scopes are visible immediately and Run once is the default', () {
    final dialog = _dialog();
    final shown = dialog.rows(width: 140).map(_text).join('\n');
    expect(shown, contains('❯ [y] Run once'));
    expect(
        shown,
        contains(
            '[a] For this session: always allow commands starting with gh pr view'));
    expect(
        shown,
        contains(
            '[p] For this workspace: always allow commands starting with gh pr view'));
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
