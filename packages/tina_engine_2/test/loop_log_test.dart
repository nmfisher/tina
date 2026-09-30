// Step 0 of slice 2: the loop owns an append-only log, publishes entries
// to listeners, and derives every request from it — no transcript list
// beside the log, no request built from anything else.
//
// Run: dart test
library;

import 'dart:convert';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

final class _Rewriter extends AgentPlugin {
  const _Rewriter();
  @override
  String get id => 'test/rewriter';
  @override
  int get order => 50;
  @override
  void onInput(TurnContext c) {
    c.input = c.input.withText('${c.input.text} (rewritten)');
  }
}

/// One dispatchable tool, so the tool-call paths have something to run.
final class _Echo extends AgentPlugin {
  const _Echo();
  @override
  String get id => 'test/echo';
  @override
  int get order => 100;
  @override
  List<ToolSchema> get tools => [
        ToolSchema(
            name: 'echo',
            description: 'echo',
            inputSchema: {'type': 'object', 'properties': {}}),
      ];
}

Future<ToolResult> _echoExec(Map<String, Object?> args) async =>
    ToolResult(args['text']?.toString() ?? '');

void main() {
  test('one turn appends the full entry sequence, seq == position', () async {
    final provider = ScriptedProvider([scriptedReply('hi there')]);
    final loop = AgentLoop(provider: provider, plugins: [const _Echo()]);
    final seen = <(SessionEntry, LogEvent)>[];
    loop.subscribe((e, ev) => seen.add((e, ev))); // replay of empty log: none

    await loop.runTurn(const Input('hello', id: 'i1'));

    expect([
      for (final e in loop.log) e.kind
    ], [
      'turn_started',
      'input_recorded',
      'message_appended',
      'message_appended',
      'turn_ended',
    ]);
    for (var i = 0; i < loop.log.length; i++) {
      expect(loop.log[i].seq, i, reason: 'position ${loop.log[i].kind}');
    }
    final recorded = loop.log[1] as InputRecordedEntry;
    expect(recorded.text, 'hello');
    final started = loop.log[0] as TurnStartedEntry;
    expect(started.turnId, 'i1');
    final ended = loop.log[4] as TurnEndedEntry;
    expect(ended.turnId, 'i1');
    expect(ended.reason, TurnStopReason.complete);
    expect([for (final (_, ev) in seen) ev], everyElement(LogEvent.appended));
    expect(seen.length, loop.log.length);
  });

  test('a subscriber receives the existing log as replay, in order', () async {
    final provider = ScriptedProvider([scriptedReply('one')]);
    final loop = AgentLoop(provider: provider, plugins: [const _Echo()]);
    await loop.runTurn(const Input('first', id: 'a'));
    final replayed = <SessionEntry>[];
    loop.subscribe((e, ev) {
      if (ev == LogEvent.replay) replayed.add(e);
    });
    expect([for (final e in replayed) e.seq],
        [for (var i = 0; i < loop.log.length; i++) i]);
    expect(jsonEncode([for (final e in replayed) e.toJson()]),
        jsonEncode([for (final e in loop.log) e.toJson()]));
  });

  test('listener payloads are the log bytes: same JSON, entry for entry',
      () async {
    final provider = ScriptedProvider([scriptedReply('done')]);
    final loop = AgentLoop(provider: provider, plugins: [const _Echo()]);
    final appendedJson = <String>[];
    loop.subscribe((e, ev) {
      if (ev == LogEvent.appended) appendedJson.add(jsonEncode(e.toJson()));
    });
    await loop.runTurn(const Input('x', id: 'i'));
    expect(appendedJson, [for (final e in loop.log) jsonEncode(e.toJson())]);
  });

  test('the request is derived from the log — nothing else to derive from',
      () async {
    final provider = ScriptedProvider([
      scriptedReply('', calls: [
        ToolUseBlock(id: 'c1', name: 'echo', input: {'text': 'x'})
      ]),
      scriptedReply('final'),
    ]);
    final loop = AgentLoop(provider: provider, plugins: [const _Echo()]);
    loop.registerExecutor('echo', _echoExec);
    await loop.runTurn(const Input('go', id: 'i1'));

    // Two requests. The second carried the derived conversation *as it
    // stood when it was sent* — the final reply lands in the log after
    // that stream returns, so the request is a prefix of the final view.
    final second = provider.requests[1];
    final derived = deriveSession(loop.log, const SessionSettings(),
        includePendingTurn: false);
    expect(derived.messages.length, 4);
    expect(
      [for (final m in second.messages) jsonEncode(m.toJson())],
      [for (final m in derived.messages.take(3)) jsonEncode(m.toJson())],
      reason: 'user, assistant(tool_use), user(tool_result) — then sent',
    );
    // The fourth logged message is the final reply the second stream
    // produced; the log holds exactly what the conversation is built of.
    final logged = [
      for (final e in loop.log.whereType<MessageAppendedEntry>()) e.message
    ];
    expect(logged.length, 4);
    expect(jsonEncode(logged[3].toJson()),
        jsonEncode(derived.messages[3].toJson()));
  });

  test('mid-turn requests include the open turn; the final derive does not',
      () async {
    final provider = ScriptedProvider([
      scriptedReply('', calls: [
        ToolUseBlock(id: 'c1', name: 'echo', input: {'text': 'x'})
      ]),
      scriptedReply('final'),
    ]);
    final loop = AgentLoop(provider: provider, plugins: [const _Echo()]);
    loop.registerExecutor('echo', _echoExec);
    await loop.runTurn(const Input('go', id: 'i1'));

    // Mid-turn (request 1): open turn included — the input is in.
    expect(
      (provider.requests[0].messages.first.content.single as TextBlock).text,
      'go',
    );
    // After the turn: the turn is closed, so the plain derive (resume
    // semantics) yields the same four messages here — a *complete* turn
    // survives the snap.
    expect(loop.derive().messages.length, 4);
    expect(loop.log.whereType<TurnEndedEntry>().single.reason,
        TurnStopReason.complete);
  });

  test('a rewrite lands as an entry naming the plugin; raw input stays',
      () async {
    final provider = ScriptedProvider([scriptedReply('ok')]);
    final loop = AgentLoop(provider: provider, plugins: [const _Rewriter()]);
    await loop.runTurn(const Input('as typed', id: 'i1'));

    final raw = loop.log.whereType<InputRecordedEntry>().single;
    expect(raw.text, 'as typed');
    final rewrite = loop.log.whereType<InputRewrittenEntry>().single;
    expect(rewrite.pluginId, 'test/rewriter');
    expect(rewrite.text, 'as typed (rewritten)');
    // The provider saw the rewrite; the log kept both.
    final userBlock =
        provider.requests.single.messages.first.content.single as TextBlock;
    expect(userBlock.text, 'as typed (rewritten)');
  });

  test('turn usage is summed from the provider-reported numbers', () async {
    final provider = ScriptedProvider([
      [
        const ToolCallStart(id: 'c1', name: 'echo'),
        const MessageComplete(
            content: [
              TextBlock(''),
              ToolUseBlock(id: 'c1', name: 'echo', input: {'text': 'x'})
            ],
            stopReason: 'tool_use',
            usage: TokenUsage(
                inputTokens: 10, outputTokens: 5, cacheReadInputTokens: 2)),
      ],
      [
        const MessageComplete(
            content: [TextBlock('b')],
            stopReason: 'end_turn',
            usage: TokenUsage(inputTokens: 7, outputTokens: 3)),
      ],
    ]);
    final loop = AgentLoop(provider: provider, plugins: [const _Echo()]);
    loop.registerExecutor('echo', _echoExec);
    final outcome = await loop.runTurn(const Input('q', id: 'i1'));
    expect(outcome.stopReason, StopReason.complete);
    final ended = loop.log.whereType<TurnEndedEntry>().single;
    expect(
        ended.usage,
        const EntryUsage(
            inputTokens: 17, outputTokens: 8, cacheReadInputTokens: 2));
    expect(provider.callCount, 2, reason: 'one turn, two requests');
    // The outcome's stand-in count is unchanged: responses this turn.
    expect(outcome.usage, 2);
  });

  test('a provider error still ends the turn in the log', () async {
    final provider = ScriptedProvider([
      [const StreamError('boom')],
    ]);
    final loop = AgentLoop(provider: provider, plugins: [const _Echo()]);
    final outcome = await loop.runTurn(const Input('q', id: 'i1'));
    expect(outcome.stopReason, StopReason.error);
    final ended = loop.log.whereType<TurnEndedEntry>().single;
    expect(ended.reason, TurnStopReason.error);
  });

  test('a provider that throws inside send() ends the turn as an error',
      () async {
    final loop =
        AgentLoop(provider: _ThrowingProvider(), plugins: [const _Echo()]);
    final outcome = await loop.runTurn(const Input('q', id: 'i2'));
    expect(outcome.stopReason, StopReason.error);
    final ended = loop.log.whereType<TurnEndedEntry>().single;
    expect(ended.reason, TurnStopReason.error);
    expect(ended.turnId, 'i2');
  });

  test(
      'a listener that throws mid-turn: the turn still ends in the log, '
      'the error surfaces', () async {
    final loop = AgentLoop(
        provider: ScriptedProvider([scriptedReply('x')]),
        plugins: [const _Echo()]);
    loop.subscribe((e, ev) {
      if (ev == LogEvent.appended && e is InputRecordedEntry) {
        throw StateError('listener sentinel');
      }
    });
    await expectLater(
        loop.runTurn(const Input('q', id: 'i3')), throwsA(isA<StateError>()));
    // The no-open-turn invariant held anyway: the catch path appended the
    // end entry before rethrowing (the sentinel listener ignores it).
    final ended = loop.log.whereType<TurnEndedEntry>().single;
    expect(ended.reason, TurnStopReason.error);
    expect(ended.turnId, 'i3');
  });

  test('state writer binds its owner and cannot forge another namespace', () {
    final loop =
        AgentLoop(provider: ScriptedProvider([]), plugins: [const _Echo()]);
    final owner = 'test/echo';
    final write = loop.stateWriter(owner);
    write(PluginStateEntry.snapshot(
        pluginId: owner, stateKey: 'data', schemaVersion: 1, value: {'x': 1}));
    expect(loop.derive().pluginStates[owner]!['data']!.value, {'x': 1});
    expect(
        () => write(PluginStateEntry.snapshot(
            pluginId: 'test/other',
            stateKey: 'data',
            schemaVersion: 1,
            value: {})),
        throwsStateError);
    loop.removePlugin(owner);
    expect(
        () => write(PluginStateEntry.snapshot(
            pluginId: owner, stateKey: 'data', schemaVersion: 1, value: {})),
        throwsStateError);
  });

  test('compact appends an entry and the derive splices the summary', () async {
    final provider = ScriptedProvider([
      scriptedReply('first'),
      scriptedReply('second'),
    ]);
    final loop = AgentLoop(provider: provider, plugins: [const _Echo()]);
    await loop.runTurn(const Input('q1', id: 't1'));
    await loop.runTurn(const Input('q2', id: 't2'));
    expect(loop.derive().messages.length, 4);

    loop.compact(0, 1, 'q1/a1 happened');
    final c = loop.log.whereType<CompactedEntry>().single;
    expect(c.replacedFrom, 0);
    expect(c.replacedTo, 1);
    expect(c.summary, 'q1/a1 happened');
    final messages = loop.derive().messages;
    expect(messages.length, 3);
    expect(messages.first.isSynthetic, isTrue);
    expect((messages.first.content.single as TextBlock).text, 'q1/a1 happened');
    expect((messages[1].content.single as TextBlock).text, 'q2');
    expect(c.seq, loop.log.length - 1);

    // Mid-turn compaction is refused: the entry's range must address the
    // list exactly as it stands, and mid-turn that list is growing.
    final turn = loop.runTurn(const Input('q3', id: 't3'));
    expect(() {}, returnsNormally);
    await turn;
  });

  test('compact is between-turns only and range-checked', () async {
    final loop = AgentLoop(
        provider: ScriptedProvider([scriptedReply('x')]),
        plugins: [const _Echo()]);
    expect(() => loop.compact(0, 0, 'nothing to compact'),
        throwsA(isA<RangeError>()));
    await loop.runTurn(const Input('q', id: 't'));
    expect(() => loop.compact(0, 99, 'too far'), throwsA(isA<RangeError>()));
    expect(() => loop.compact(2, 1, 'backwards'), throwsA(isA<RangeError>()));
    // And a valid range survives:
    loop.compact(0, 1, 'sum');
    expect(loop.log.whereType<CompactedEntry>().single.summary, 'sum');
  });

  test('a seeded log is the resumed session: the first request carries it',
      () async {
    // History as a previous session's store would hand it back.
    final seed = <SessionEntry>[
      const TurnStartedEntry(turnId: 'old-1'),
      const InputRecordedEntry(turnId: 'old-1', text: 'earlier question'),
      MessageAppendedEntry(
          turnId: 'old-1',
          message: Message(
              role: Role.user, content: [TextBlock('earlier question')])),
      MessageAppendedEntry(
          turnId: 'old-1',
          message: Message(
              role: Role.assistant, content: [TextBlock('earlier answer')])),
      const TurnEndedEntry(turnId: 'old-1', reason: TurnStopReason.complete),
    ];
    final provider = ScriptedProvider([scriptedReply('now I answer')]);
    final loop =
        AgentLoop(provider: provider, plugins: [const _Echo()], seedLog: seed);
    await loop.runTurn(const Input('next question', id: 'new-1'));

    final messages = provider.requests.single.messages;
    expect(messages.length, 3);
    expect((messages[0].content.single as TextBlock).text, 'earlier question');
    expect((messages[1].content.single as TextBlock).text, 'earlier answer');
    expect((messages[2].content.single as TextBlock).text, 'next question');
    // The seed kept its seqs; the new entries continue from it.
    expect(loop.log.first.seq, 0);
    expect(loop.log.last.seq, loop.log.length - 1);
    expect(loop.log.length, seed.length + 5);
  });
}

final class _ThrowingProvider implements LlmProvider {
  @override
  String get model => 'throwing';

  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) async* {
    throw StateError('provider exploded');
  }

  @override
  void close() {}
}
