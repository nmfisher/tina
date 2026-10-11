// B3, context side: ContextPlugin implements MessageProjection. loop.compact
// between turns routes through the plugin — the working context is rewritten
// (summary spliced in, revision bumped) and no CompactedEntry is appended,
// so the projection-owned view stays derivable. The next model request is
// built from the compacted projection.
library;

import 'package:test/test.dart';
import 'package:tina_context/tina_context.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

Message text(String value, [Role role = Role.user]) =>
    Message(role: role, content: [TextBlock(value)]);

List<String> texts(Iterable<Message> messages) => [
      for (final m in messages)
        for (final b in m.content.whereType<TextBlock>()) b.text,
    ];

List<SessionEntry> stamp(List<SessionEntry> entries) => [
      for (var i = 0; i < entries.length; i++) entries[i].withSeq(i),
    ];

List<SessionEntry> completedHistory() => stamp([
      const TurnStartedEntry(turnId: 'a'),
      MessageAppendedEntry(turnId: 'a', message: text('q')),
      MessageAppendedEntry(turnId: 'a', message: text('a', Role.assistant)),
      const TurnEndedEntry(turnId: 'a', reason: TurnStopReason.complete),
    ]);

void main() {
  test('loop.compact routes through the context projection', () async {
    final provider = ScriptedProvider([scriptedReply('done')]);
    final plugin = ContextPlugin();
    final loop = AgentLoop(
        provider: provider, plugins: [plugin], seedLog: completedHistory());
    loop.mountPlugin(plugin);

    loop.compact(0, 1, 'the whole exchange, summarized');

    // No CompactedEntry anywhere: the projection owns the splice.
    expect(
        [for (final e in loop.log) e.kind], everyElement(isNot('compacted')));
    // The projection rewrote itself: the summary replaces BOTH messages
    // (0..1 inclusive), revision bumped.
    final context = plugin.workingContext;
    expect(texts(context.messages), ['the whole exchange, summarized']);
    expect(context.revision, 1);
    expect(
        context.messages.singleWhere((m) => m.isSynthetic).content.single
            is TextBlock,
        isTrue);
    // Derivation still works — no "compaction cannot follow an edit".
    expect(() => loop.derive(), returnsNormally);
  });

  test('the next request is built from the compacted projection', () async {
    final provider = ScriptedProvider([scriptedReply('done')]);
    final plugin = ContextPlugin();
    final loop = AgentLoop(
        provider: provider, plugins: [plugin], seedLog: completedHistory());
    loop.mountPlugin(plugin);
    loop.compact(0, 1, 'summary of q and a');
    await loop.runTurn(const Input('next', id: 'b'));
    // The request as sent: the compacted projection plus the new input.
    expect(texts(provider.requests.single.messages),
        ['summary of q and a', 'next']);
  });

  test('a splice the projection cannot address throws, log untouched',
      () async {
    final provider = ScriptedProvider([]);
    final plugin = ContextPlugin();
    final loop = AgentLoop(
        provider: provider, plugins: [plugin], seedLog: completedHistory());
    loop.mountPlugin(plugin);
    final before = loop.log.length;
    // Core derive has 2 messages; index 1 passes its range check, but is
    // outside the edited projection.
    plugin.replaceWorkingContext(
        expectedRevision: 0,
        expectedThroughSeq: 3,
        messages: [text('only one now')]);
    expect(() => loop.compact(1, 1, 'too far'), throwsA(isA<StateError>()));
    expect(loop.log.length, before + 1,
        reason: 'only the edit snapshot was appended, never a compacted '
            'entry or a half-served splice');
    expect(
        [for (final e in loop.log) e.kind], everyElement(isNot('compacted')));
  });

  for (final replacement in [
    [text('a', Role.assistant)],
    [text('different question'), text('different answer', Role.assistant)],
    [text('a', Role.assistant), text('q')],
    [
      text('inserted'),
      ...[text('q'), text('a', Role.assistant)]
    ],
  ]) {
    for (final resume in [false, true]) {
      test(
          'in-bounds compaction refuses a divergent projection '
          '${texts(replacement)} (resume: $resume)', () {
        var plugin = ContextPlugin();
        var loop = AgentLoop(
            provider: ScriptedProvider([]),
            plugins: [plugin],
            seedLog: completedHistory());
        loop.mountPlugin(plugin);
        plugin.replaceWorkingContext(
            expectedRevision: 0, expectedThroughSeq: 3, messages: replacement);
        if (resume) {
          final seed = List<SessionEntry>.of(loop.log);
          plugin = ContextPlugin();
          loop = AgentLoop(
              provider: ScriptedProvider([]), plugins: [plugin], seedLog: seed);
          loop.mountPlugin(plugin);
        }
        final before = List<SessionEntry>.of(loop.log);
        expect(() => loop.compact(0, 0, 'summary of original question'),
            throwsStateError);
        expect(loop.log, before);
        expect(texts(plugin.workingContext.messages), texts(replacement));
      });
    }
  }

  test('a snapshot with unchanged content can still be compacted', () {
    final plugin = ContextPlugin();
    final loop = AgentLoop(
        provider: ScriptedProvider([]),
        plugins: [plugin],
        seedLog: completedHistory());
    loop.mountPlugin(plugin);
    plugin.replaceWorkingContext(
        expectedRevision: 0,
        expectedThroughSeq: 3,
        messages: [text('q'), text('a', Role.assistant)]);
    loop.compact(0, 1, 'summary');
    expect(texts(plugin.workingContext.messages), ['summary']);
    expect(plugin.workingContext.revision, 2);
  });
}
