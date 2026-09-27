import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_tui/tina_tui.dart';

/// Headless: the dialog driven from scripted keys — no terminal.
void main() {
  final call = const ToolUse(
    id: 'c1',
    name: 'bash',
    input: {'command': 'rm -rf build/'},
  );

  test('the decision comes from scripted keys: enter on default allows', () async {
    final outcome = await ApprovalDialog(call)
        .awaitDecision(ScriptedKeySource([ApprovalKey.confirm]));
    expect(outcome.decision, ApprovalDecision.allowAlways);
    expect(outcome.isCancellation, isFalse);
  });

  test('down moves to allow, again to deny; enter confirms deny', () async {
    final outcome = await ApprovalDialog(call).awaitDecision(
      ScriptedKeySource(
          [ApprovalKey.down, ApprovalKey.down, ApprovalKey.confirm]),
    );
    expect(outcome.decision, ApprovalDecision.deny);
  });

  test('up and down cannot leave the choice list', () async {
    final outcome = await ApprovalDialog(call).awaitDecision(
      ScriptedKeySource(
          [ApprovalKey.up, ApprovalKey.up, ApprovalKey.confirm]),
    );
    expect(outcome.decision, ApprovalDecision.allowAlways);
  });

  test('escape cancels: a denial, marked cancelled', () async {
    final outcome = await ApprovalDialog(call)
        .awaitDecision(ScriptedKeySource([ApprovalKey.cancel]));
    expect(outcome.decision, ApprovalDecision.deny);
    expect(outcome.isCancellation, isTrue);
  });

  test('a closed key source denies without throwing', () async {
    final outcome =
        await ApprovalDialog(call).awaitDecision(ScriptedKeySource([]));
    expect(outcome.decision, ApprovalDecision.deny);
    expect(outcome.isCancellation, isTrue);
  });

  test('a call with a parse error is never offered "allow always"', () async {
    final broken = const ToolUse(
      id: 'c2',
      name: 'bash',
      input: {},
      argumentsParseError: 'bad JSON',
    );
    final dialog = ApprovalDialog(broken);
    // First choice is now plain allow.
    final outcome =
        await dialog.awaitDecision(ScriptedKeySource([ApprovalKey.confirm]));
    expect(outcome.decision, ApprovalDecision.allow);
  });

  test('rows show the call, its args, and one marker per choice', () {
    final rows = ApprovalDialog(call).rows(width: 80);
    final texts = rows.map((r) => r.runs.single.text).toList();
    expect(texts.first, '┌─ Run command');
    expect(texts.any((t) => t.contains('rm -rf build/')), isTrue);
    expect(texts.where((t) => t.contains('[x]')), hasLength(1));
    expect(texts.where((t) => t.contains('[ ]')), hasLength(2));
    expect(texts.any((t) => t.contains('allow always')), isTrue);
    expect(texts.last, contains('esc deny'));
  });

  test('selected choice is highlighted with the dialog style', () {
    final dialog = ApprovalDialog(call);
    final rows = dialog.rows();
    final selected =
        rows.firstWhere((r) => r.runs.single.text.contains('[x]'));
    expect(selected.runs.single.code, Theme.defaults().dialog.confirm);
    dialog.handleKey(ApprovalKey.down);
    final moved = dialog.rows();
    // Exactly one *choice* row is highlighted (the top border may share the
    // dialog style); after one ↓ it is the plain allow, not allow-always.
    final highlighted =
        moved.where((r) => r.runs.single.text.contains('[x]')).toList();
    expect(highlighted, hasLength(1));
    expect(highlighted.single.runs.single.text, contains('allow'));
    expect(
        highlighted.single.runs.single.text, isNot(contains('allow always')));
    expect(highlighted.single.runs.single.code,
        Theme.defaults().dialog.confirm);
  });

  test('long arguments clip to the width', () {
    final wide = ToolUse(
      id: 'c3',
      name: 'write',
      input: {'path': 'a.txt', 'content': 'y' * 200},
    );
    final rows = ApprovalDialog(wide).rows(width: 40);
    for (final row in rows) {
      expect(visibleWidth(row.runs.single.text), lessThanOrEqualTo(40));
    }
  });
}
