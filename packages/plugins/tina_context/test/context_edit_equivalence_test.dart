import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_context/tina_context.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

Message text(String value, [Role role = Role.user]) =>
    Message(role: role, content: [TextBlock(value)]);

List<SessionEntry> history() => [
      const TurnStartedEntry(turnId: 'a', seq: 0),
      MessageAppendedEntry(turnId: 'a', message: text('question'), seq: 1),
      MessageAppendedEntry(
          turnId: 'a', message: text('answer', Role.assistant), seq: 2),
      const TurnEndedEntry(
          turnId: 'a', reason: TurnStopReason.complete, seq: 3),
    ];

void main() {
  test('plugin rethrows per-rule error types exactly as before extraction',
      () {
    final plugin = ContextPlugin();
    final loop = AgentLoop(
        provider: ScriptedProvider([]), plugins: [plugin], seedLog: history());
    loop.mountPlugin(plugin);

    // Stale counters → ContextEditRejected (StateError subclass).
    final stale = plugin.workingContext;
    expect(
        () => plugin.replaceWorkingContext(
            expectedRevision: stale.revision,
            expectedThroughSeq: stale.throughSeq + 5,
            messages: [text('x')]),
        throwsA(isA<ContextEditRejected>()
            .having((e) => e.message, 'message', 'Stale working-context edit')));

    // Structural (unpaired result) → FormatException, log untouched.
    final current = plugin.workingContext;
    final count = loop.log.length;
    expect(
        () => plugin.replaceWorkingContext(
            expectedRevision: current.revision,
            expectedThroughSeq: current.throughSeq,
            messages: [
              Message(
                  role: Role.user,
                  content: [ToolResultBlock(toolUseId: 'ghost', content: 'x')])
            ]),
        throwsFormatException);
    expect(loop.log.length, count);

    // Structural (signed reasoning) → FormatException with exact string.
    expect(
        () => plugin.replaceWorkingContext(
            expectedRevision: current.revision,
            expectedThroughSeq: current.throughSeq,
            messages: const [
              Message(
                  role: Role.assistant,
                  content: [TextBlock('a')],
                  reasoning: [ReasoningBlock('forged', signature: 'nope')])
            ]),
        throwsA(isA<FormatException>().having(
            (e) => e.message, 'message', 'Signed reasoning must remain intact')));
  });

  test('mirror rejects via the shared verdict and reports the collapsed receipt',
      () {
    final dir = Directory.systemTemp.createTempSync('tina-context-equiv-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/live.json');
    final base =
        WorkingContext(revision: 1, throughSeq: 3, messages: [text('saved')]);
    final mirror = ContextFileMirror(file);
    mirror.initialize(base);

    // Stale current (another edit landed): the pure function rejects with
    // 'Stale context file'; the mirror collapses it into its fixed receipt
    // and republishes current state.
    final moved = WorkingContext(
        revision: 2, throughSeq: 4, messages: [text('other edit')]);
    file.writeAsStringSync(
        jsonEncode(jsonDecode(file.readAsStringSync())
          ..['messages'] = [text('edited').toJson()]));
    final result = mirror.synchronize(moved, (_) => throw StateError('never'));
    expect(mirror.lastReceipt!.status, ContextEditStatus.rejected);
    expect(
        mirror.lastReceipt!.message,
        contains('Context edit rejected: invalid, stale, or protected '
            'content.'));
    expect(result.messages, hasLength(1));
    expect(jsonDecode(file.readAsStringSync())['revision'], moved.revision);

    // Same inputs through the pure function agree on the reason.
    final verdict = evaluateContextEdit(
        current: moved,
        edited: [text('edited')],
        base: base);
    expect(verdict, isA<ContextEditRejectedVerdict>());
    expect((verdict as ContextEditRejectedVerdict).problem.message,
        'Stale context file');
  });

  test('mirror accepts through the shared verdict and bumps revision', () {
    final dir = Directory.systemTemp.createTempSync('tina-context-equiv-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/live.json');
    final base =
        WorkingContext(revision: 1, throughSeq: 3, messages: [text('saved')]);
    final mirror = ContextFileMirror(file);
    mirror.initialize(base);

    file.writeAsStringSync(
        jsonEncode(jsonDecode(file.readAsStringSync())
          ..['messages'] = [text('edited').toJson()]));
    var written = const <Message>[]; // sentinel; replaced on call
    mirror.synchronize(base, (merged) {
      written = merged;
      return base;
    });
    expect(mirror.lastReceipt!.status, ContextEditStatus.accepted);
    // The replace callback received the pure function's merged list.
    expect([for (final m in written) (m.content.single as TextBlock).text],
        ['edited']);
  });
}
