import 'package:test/test.dart';
import 'package:tina_context/tina_context.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

Message text(String value, [Role role = Role.user]) =>
    Message(role: role, content: [TextBlock(value)]);

Message call(String id) => Message(
    role: Role.assistant, content: [ToolUseBlock(id: id, name: 'tool', input: {})]);

Message result(String id) => Message(
    role: Role.user, content: [ToolResultBlock(toolUseId: id, content: 'out')]);

void main() {
  // A settled two-message turn: request preserved, no pending calls.
  WorkingContext context(List<Message> messages, {int revision = 1}) =>
      WorkingContext(
          revision: revision,
          throughSeq: messages.length - 1,
          messages: messages);

  test('unchanged proposal against the base is an unchanged verdict', () {
    final base = context([text('saved')]);
    final verdict = evaluateContextEdit(
        current: base, edited: [text('saved')], base: base);
    expect(verdict, isA<ContextEditUnchanged>());
  });

  test('stale base (revision moved) is rejected with the exact legacy string',
      () {
    final base = context([text('saved')]);
    final current = context([text('other')], revision: 2);
    final verdict = evaluateContextEdit(
        current: current, edited: [text('edited')], base: base);
    expect(verdict, isA<ContextEditRejectedVerdict>());
    final problem = (verdict as ContextEditRejectedVerdict).problem;
    expect(problem.kind, ContextEditProblemKind.stale);
    expect(problem.message, 'Stale context file');
  });

  test('rebase appends messages that arrived after the export', () {
    final base = context([text('saved')]);
    final current = WorkingContext(
        revision: 1,
        throughSeq: 5,
        messages: [text('saved'), text('newer'), text('newest')]);
    final verdict = evaluateContextEdit(
        current: current,
        edited: [text('edited')],
        base: base,
        activeTurn: ActiveTurnContext(
            turnId: 'b', messages: [text('newer'), text('newest')]));
    expect(verdict, isA<ContextEditAccepted>());
    final merged = (verdict as ContextEditAccepted).merged;
    expect([for (final m in merged) (m.content.single as TextBlock).text],
        ['edited', 'newer', 'newest']);
  });

  test('unpaired tool result is a structural rejection', () {
    final verdict = evaluateContextEdit(
        current: context([text('a')]), edited: [result('unknown')]);
    final problem = (verdict as ContextEditRejectedVerdict).problem;
    expect(problem.kind, ContextEditProblemKind.structural);
    expect(problem.message, 'Unpaired or duplicate tool result');
  });

  test('signed reasoning mutation is a structural rejection', () {
    final current = context([
      const Message(
          role: Role.assistant,
          content: [TextBlock('answer')],
          reasoning: [ReasoningBlock('original', signature: 'sig')])
    ]);
    final verdict = evaluateContextEdit(current: current, edited: [
      const Message(
          role: Role.assistant,
          content: [TextBlock('answer')],
          reasoning: [ReasoningBlock('modified', signature: 'sig')])
    ]);
    final problem = (verdict as ContextEditRejectedVerdict).problem;
    expect(problem.kind, ContextEditProblemKind.structural);
    expect(problem.message, 'Signed reasoning must remain intact');
  });

  test('dropping the current request is a protected rejection', () {
    final verdict = evaluateContextEdit(
        current: context([text('task')]),
        edited: [text('notes only')],
        activeTurn:
            ActiveTurnContext(turnId: 'b', messages: [text('task')]));
    final problem = (verdict as ContextEditRejectedVerdict).problem;
    expect(problem.kind, ContextEditProblemKind.protected);
    expect(problem.message, 'The current user request must remain intact');
  });

  test('an unsettled executing batch is a protected rejection', () {
    // The edited list is structurally valid and keeps the request, but the
    // turn itself still has an outstanding call: structural validation
    // passes (nothing dangles in the proposal) and the protected rule fires.
    final verdict = evaluateContextEdit(
        current: context([text('task'), call('one')]),
        edited: [text('task')],
        activeTurn: ActiveTurnContext(
            turnId: 'b', messages: [text('task'), call('one')]));
    final problem = (verdict as ContextEditRejectedVerdict).problem;
    expect(problem.kind, ContextEditProblemKind.protected);
    expect(problem.message, 'The executing tool batch must settle first');
  });

  test('an unpaired call inside the proposal is structural, not protected',
      () {
    // Firing order preserved from the pre-extraction pipeline: structural
    // validation runs before the in-turn checks.
    final verdict = evaluateContextEdit(
        current: context([text('task'), call('one')]),
        edited: [text('task'), call('one')],
        activeTurn: ActiveTurnContext(
            turnId: 'b', messages: [text('task'), call('one')]));
    final problem = (verdict as ContextEditRejectedVerdict).problem;
    expect(problem.kind, ContextEditProblemKind.structural);
    expect(problem.message, 'Missing tool results');
  });

  test('a well-formed direct replacement is accepted frozen', () {
    final verdict = evaluateContextEdit(
        current: context([text('old')]), edited: [text('fresh')]);
    expect(verdict, isA<ContextEditAccepted>());
    final merged = (verdict as ContextEditAccepted).merged;
    expect(merged, hasLength(1));
    expect(() => merged.clear(), throwsUnsupportedError);
  });

  test('accepted merged lists pass full structural validation', () {
    final verdict = evaluateContextEdit(
        current: context([text('old')]), edited: [call('x'), result('x')]);
    expect(verdict, isA<ContextEditAccepted>());
  });
}
