// The approval dialog in ask mode: a permission question straight from the
// sandbox — no tool call, just the operation, the resolved path, the reason
// — and the same three answers as any dialog.
//
// Run: dart test
library;

import 'package:test/test.dart';
import 'package:tina_approvals_tui/tina_approvals_tui.dart';

void main() {
  ApprovalDialog askDialog({
    String op = 'write',
    String path = '/tmp/elsewhere/out.txt',
    String reason = 'outside the project root',
  }) =>
      ApprovalDialog(
        null,
        ask: ApprovalAskContext(op, path, reason),
      );

  List<String> text(List<dynamic> rows) =>
      [for (final r in rows) r.runs.map((run) => run.text).join()];

  test('an ask dialog shows the operation, the resolved path and the reason',
      () {
    final lines = text(askDialog().rows(width: 200));
    expect(lines.first, contains('Write outside the project'));
    expect(lines.any((l) => l.contains('path: /tmp/elsewhere/out.txt')), isTrue,
        reason: 'the resolved path is shown');
    expect(
        lines.any((l) => l.contains('why: outside the project root')), isTrue,
        reason: 'the reason is shown verbatim');
  });

  test('the three answers are offered: allow always, allow, deny', () {
    final lines = text(askDialog().rows(width: 200));
    expect(lines.where((l) => l.contains('allow always')), hasLength(1));
    expect(lines.where((l) => l.contains('[ ] allow')), hasLength(1));
    expect(lines.where((l) => l.contains('[ ] deny')), hasLength(1));
  });

  test('a read ask is labeled as a read', () {
    final lines = text(askDialog(op: 'read').rows(width: 200));
    expect(lines.first, contains('Read outside the project'));
  });

  test('confirm returns the highlighted choice; deny is reachable by ↓↓',
      () async {
    final outcome = await askDialog().awaitDecision(ScriptedKeySource(
        [ApprovalKey.down, ApprovalKey.down, ApprovalKey.confirm]));
    expect(outcome.decision, ApprovalDecision.deny);
  });

  test('esc cancels the ask: a denial, never a silent allow', () async {
    final outcome = await askDialog()
        .awaitDecision(ScriptedKeySource([ApprovalKey.cancel]));
    expect(outcome.decision, ApprovalDecision.deny);
    expect(outcome.reason, 'cancelled');
  });

  test('a dialog with neither call nor ask refuses to render', () {
    expect(() => ApprovalDialog(null).rows(), throwsStateError);
  });
}
