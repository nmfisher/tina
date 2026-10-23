import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_approvals_tui/tina_approvals_tui.dart';
import 'package:tina_console/tina_console.dart';

const command = 'dart test sometest | head -n2';
const pattern = r'dart test sometest \| head -n[0-9]+';
const request = ApprovalRequest(
    id: 'test',
    operation: 'run command',
    target: command,
    reason: 'execution approval',
    details: {
      'command_pattern_target': command,
      'persistent_command_pattern': true,
      'required_permissions': ['execution'],
      'cwd': '/project',
    });
Future<void> tick() => Future<void>.delayed(Duration.zero);
ControlKey enter() => ControlKey(ControlCode.enter);
String shown(CommandPatternReview review, {int width = 80, int height = 24}) =>
    review
        .rows(width: width, height: height, theme: const Theme.defaults())
        .map((row) => row.runs.map((run) => run.text).join())
        .join('\n');

void main() {
  test('multiline commands have a usable single-line literal fallback', () {
    const target = 'printf hello\nprintf world\t';
    final review = CommandPatternReview(const ApprovalRequest(
        id: 'multiline',
        operation: 'run command',
        target: target,
        reason: 'execute',
        details: {'command_pattern_target': target}));
    addTearDown(review.close);
    expect(review.input.buffer, isNot(contains('\n')));
    expect(review.input.buffer, contains(r'\x0a'));
    expect(CommandApprovalPattern(review.input.buffer).matches(target), true);
    expect(review.handle(enter()), CommandPatternReviewResult.pending);
    expect(review.reviewing, true);
    expect(shown(review), isNot(contains('Allow and save for this workspace')));
  });
  test('choosing the regex editor leaves the command pending', () async {
    final dialog = ApprovalDialog(null,
        ask: ApprovalAskContext('run command', command, 'execution approval',
            details: request.details));
    final outcome = await dialog.awaitDecision(ScriptedKeySource(
        [ApprovalKey.always, ApprovalKey.editCommandPattern]));
    expect(outcome.editCommandPattern, true);
    expect(outcome.commandPattern, isNull);
    expect(dialog.rows().map((r) => r.runs.map((v) => v.text).join()).join(),
        contains('[e] Approve with an editable regex'));
  });

  test(
      'model suggestion is editable and requires review then scoped confirmation',
      () async {
    var calls = 0;
    final review = CommandPatternReview(request, suggest: (req, _) async {
      calls++;
      expect(req, same(request));
      return (
        pattern: pattern,
        explanation: 'Only the numeric line limit varies.',
        failure: null
      );
    });
    addTearDown(review.close);
    await tick();
    expect(calls, 1);
    expect(review.input.buffer, pattern);
    expect(shown(review), contains('numeric line limit'));
    expect(review.handle(enter()), CommandPatternReviewResult.pending);
    expect(review.reviewing, true);
    review.handle(ArrowKey(ArrowDirection.down));
    expect(review.handle(enter()), CommandPatternReviewResult.approved);
    expect(review.outcome.commandPattern, pattern);
    expect(review.outcome.decision, ApprovalDecision.allowWorkspace);
  });

  test('a late suggestion never replaces an edit or a rule under review',
      () async {
    for (final edit in [true, false]) {
      final result = Completer<CommandPatternSuggestion>();
      final review =
          CommandPatternReview(request, suggest: (_, __) => result.future);
      addTearDown(review.close);
      if (edit) {
        review.handle(ControlKey(ControlCode.backspace));
        review.handle(CharInput('[0-9]+'));
      } else {
        review.handle(enter());
      }
      final kept = review.input.buffer;
      result.complete((
        pattern: pattern,
        explanation: 'Numeric limit varies.',
        failure: null
      ));
      await tick();
      expect(review.input.buffer, kept);
      expect(review.status, contains('kept'));
    }
  });

  test('failed, malformed and partial suggestions keep the literal fallback',
      () async {
    for (final draft in <CommandPatternSuggestion>[
      (pattern: null, explanation: null, failure: 'timed out'),
      (pattern: '[', explanation: null, failure: null),
      (pattern: r'head -n[0-9]+', explanation: null, failure: null),
    ]) {
      final review =
          CommandPatternReview(request, suggest: (_, __) async => draft);
      addTearDown(review.close);
      await tick();
      expect(review.input.buffer, RegExp.escape(command));
      expect(review.status, contains('unavailable'));
      expect(review.handle(enter()), CommandPatternReviewResult.pending);
      expect(review.reviewing, true);
    }
  });

  test(
      'invalid edits are visible on small terminals and never reach confirmation',
      () {
    final review = CommandPatternReview(request);
    addTearDown(review.close);
    review.handle(EditingKey(EditingAction.killToStart));
    review.handle(PasteInput('['));
    review.handle(enter());
    expect(review.reviewing, false);
    expect(shown(review, width: 40, height: 4), contains('Error:'));
    expect(review.cursor, isNotNull);
    review.handle(EditingKey(EditingAction.killToStart));
    review.handle(PasteInput(pattern));
    review.handle(enter());
    expect(review.reviewing, true);
    for (final size in [(20, 3), (80, 10), (120, 30)]) {
      final text = shown(review, width: size.$1, height: size.$2);
      expect(text, contains('❯'));
      expect(review.cursor, isNull);
    }
    expect(review.handle(EscapeKey()), CommandPatternReviewResult.pending);
    expect(review.reviewing, false);
    expect(review.handle(EscapeKey()), CommandPatternReviewResult.back);
  });

  test('closing cancels suggestion and suppresses late repaint', () async {
    final result = Completer<CommandPatternSuggestion>();
    Future<void>? cancelled;
    var paints = 0;
    final review = CommandPatternReview(request,
        suggest: (_, signal) {
          cancelled = signal;
          return result.future;
        },
        onChange: () => paints++);
    review.close();
    await cancelled;
    result.complete((pattern: pattern, explanation: '', failure: null));
    await tick();
    expect(paints, 0);
    expect(review.input.buffer, RegExp.escape(command));
  });
}
