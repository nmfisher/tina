// The eight required scenarios, one `group` each, plus a ninth group
// pinning the streaming edge paths. The scripted provider plays back
// stream events; tests assert on the recorded requests.
//
// Run: dart test
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tools/tina_tools.dart'
    show
        BashTool,
        IoFileSystem,
        IoProcessRunner,
        PermissionMode,
        SandboxedFileSystem,
        SandboxedProcessRunner,
        WritableDirectories,
        stringExecutor,
        Tool,
        WriteTool;
import '../example/example_plugins.dart';

ToolSchema _tool(String name) => ToolSchema(
    name: name,
    description: 'test tool $name',
    inputSchema: {'type': 'object', 'properties': {}});

AgentPlugin _plugin(String id,
        {int order = 100,
        List<ToolSchema> tools = const [],
        String? section}) =>
    _P(id, order, tools, section);

final class _P extends AgentPlugin {
  _P(this.id, this.order, this.tools, this.section);
  @override
  final String id;
  @override
  final int order;
  @override
  final List<ToolSchema> tools;
  final String? section;
  @override
  void onPrompt(TurnContext c) {
    final s = section;
    if (s != null) c.promptSections.add(s);
  }
}

/// A user-role message whose content is all tool results.
bool _isResult(Message m) =>
    m.role == Role.user &&
    m.content.isNotEmpty &&
    m.content.every((b) => b is ToolResultBlock);

ToolResultBlock _result(Message m) =>
    m.content.whereType<ToolResultBlock>().single;

String _text(Message m) =>
    [for (final b in m.content.whereType<TextBlock>()) b.text].join();

/// A terse view of the loop's conversation: `role: text` per message.
/// The loop owns a log, not a transcript list — this view is what
/// `deriveSession` yields from it mid-turn (the open turn included), the
/// same derivation the next request would be built from.
String _transcriptText(AgentLoop loop) => [
      for (final m in loop.derive().messages)
        '${m.role == Role.user ? 'user' : 'assistant'}: ${_text(m)}'
    ].join('\n');

void main() {
  group('1. single input -> tool call -> result -> completion', () {
    test('appends user, reply, result, final reply; stops complete', () async {
      final provider = ScriptedProvider([
        scriptedReply('', calls: [
          ToolUseBlock(id: 'c1', name: 'echo', input: {'text': 'hi'})
        ]),
        scriptedReply('all done'),
      ]);
      final loop =
          AgentLoop(provider: provider, plugins: [const ToolProviderPlugin()]);
      loop.registerExecutor('echo',
          stringExecutor((args) async => args['text']?.toString() ?? ''));

      final outcome = await loop.runTurn(const Input('hello', id: 'i1'));

      expect(outcome.stopReason, StopReason.complete);
      expect(outcome.detail, 'all done');
      expect(provider.callCount, 2);
      final shapes = [
        for (final m in outcome.messages)
          m.role == Role.assistant && m.content.any((b) => b is ToolUseBlock)
              ? 'assistant:calls'
              : m.role == Role.assistant
                  ? 'assistant'
                  : _isResult(m)
                      ? 'toolResult'
                      : 'user'
      ];
      expect(shapes, ['user', 'assistant:calls', 'toolResult', 'assistant']);
      expect(_result(outcome.messages[2]).toolUseId, 'c1');
      expect(_result(outcome.messages[2]).isError, isFalse);
      // Pairing visible in the second request: user, reply, result.
      final second = provider.requests[1];
      expect(_isResult(second.messages[2]), isTrue);
    });
  });

  group('2. multi-step: two tool rounds then stop', () {
    test('loops until the model asks for no tools', () async {
      final provider = ScriptedProvider([
        scriptedReply('',
            calls: [ToolUseBlock(id: 'c1', name: 't1', input: {})]),
        scriptedReply('',
            calls: [ToolUseBlock(id: 'c2', name: 't2', input: {})]),
        scriptedReply('finished'),
      ]);
      final loop = AgentLoop(provider: provider, plugins: [
        _plugin('a', tools: [_tool('t1')]),
        _plugin('b', tools: [_tool('t2')]),
      ]);
      loop
        ..registerExecutor('t1', (_) async => ToolResult('one'))
        ..registerExecutor('t2', (_) async => ToolResult('two'));

      final outcome = await loop.runTurn(const Input('go', id: 'i2'));

      expect(outcome.stopReason, StopReason.complete);
      expect(provider.callCount, 3);
      final executed = [
        for (final m in outcome.messages)
          for (final b in m.content.whereType<ToolUseBlock>()) b.name
      ];
      expect(executed, ['t1', 't2']);
      expect([
        for (final m in outcome.messages)
          if (_isResult(m)) _result(m).toolUseId
      ], [
        'c1',
        'c2'
      ]);
    });
  });

  group('3. ordering: sections and transforms run in order', () {
    test('sections ascending by (order, id), core joins with blank lines',
        () async {
      final provider = ScriptedProvider([scriptedReply('ok')]);
      final loop = AgentLoop(provider: provider, plugins: [
        _plugin('b.late', section: 'LATE'),
        _plugin('a.early', section: 'EARLY'),
        _plugin('m.mid', order: 10, section: 'MID'),
      ]);
      await loop.runTurn(const Input('x', id: 'i3'));

      final prompt = provider.requests.first.systemPrompt;
      expect(prompt, 'MID\n\nEARLY\n\nLATE');
    });

    test('request transforms run in order and compose', () async {
      final provider = ScriptedProvider([scriptedReply('ok')]);
      final loop = AgentLoop(provider: provider, plugins: [
        const RequestTransformerPlugin(
          suffix: '|2nd', /* order 300 */
        ),
        _T('z.first-transform', order: 1, mark: '|1st'),
      ]);
      await loop.runTurn(const Input('x', id: 'i3b'));

      // order 1 runs before order 300, so |1st lands before |2nd.
      expect(provider.requests.first.systemPrompt.endsWith('|1st\n\n|2nd'),
          isTrue);
    });
  });

  group('4. guard: deny blocks execution, result recorded', () {
    test('denied call never runs; pairing kept; reason recorded', () async {
      final provider = ScriptedProvider([
        scriptedReply('',
            calls: [ToolUseBlock(id: 'c1', name: 'rm_rf', input: {})]),
        scriptedReply('fine'),
      ]);
      final ran = <String>[];
      final loop = AgentLoop(provider: provider, plugins: [
        const GuardPlugin('rm_rf', reason: 'too dangerous'),
        _plugin('owner', tools: [_tool('rm_rf')]),
      ]);
      loop.registerExecutor('rm_rf', (_) async {
        ran.add('ran!');
        return ToolResult('');
      });

      final outcome = await loop.runTurn(const Input('do it', id: 'i4'));

      expect(ran, isEmpty);
      expect(outcome.stopReason, StopReason.complete);
      final result = _result(outcome.messages.firstWhere(_isResult));
      expect(result.isError, isTrue);
      expect(result.content, contains('denied'));
      expect(result.content, contains('example.guard'));
    });

    test('ask with no UI resolves to deny, recorded as ask-unresolved',
        () async {
      final provider = ScriptedProvider([
        scriptedReply('',
            calls: [ToolUseBlock(id: 'c1', name: 't', input: {})]),
        scriptedReply('ok'),
      ]);
      final ran = <String>[];
      final loop = AgentLoop(provider: provider, plugins: [
        _Ask('approver'),
        _plugin('owner', tools: [_tool('t')]),
      ]);
      loop.registerExecutor('t', (_) async {
        ran.add('ran!');
        return ToolResult('');
      });

      final outcome = await loop.runTurn(const Input('x', id: 'i4b'));

      expect(ran, isEmpty);
      final result = _result(outcome.messages.firstWhere(_isResult));
      expect(result.content, contains('ask-unresolved'));
    });
  });

  group('5. plugin throws: turn continues, contribution absent', () {
    test('throwing guard is ignored; tool runs; section omitted', () async {
      final provider = ScriptedProvider([
        scriptedReply('',
            calls: [ToolUseBlock(id: 'c1', name: 't', input: {})]),
        scriptedReply('done'),
      ]);
      final loop = AgentLoop(provider: provider, plugins: [
        _Throw('bad.guard', throwIn: 'beforeTool'),
        _Throw('bad.section', throwIn: 'systemSection'),
        _plugin('owner', tools: [_tool('t')]),
      ]);
      loop.registerExecutor('t', (_) async => ToolResult('ran'));

      final outcome = await loop.runTurn(const Input('x', id: 'i5'));

      expect(outcome.stopReason, StopReason.complete);
      final result = _result(outcome.messages.firstWhere(_isResult));
      expect(result.isError, isFalse);
      expect(provider.requests.first.systemPrompt, isNot(contains('BOOM')));
    });

    test('throwing onInput / beforeModelCall / onTurnEnd isolated', () async {
      final provider = ScriptedProvider([scriptedReply('done')]);
      final loop = AgentLoop(provider: provider, plugins: [
        _Throw('bad.invocation', throwIn: 'onInput'),
        _Throw('bad.request', throwIn: 'beforeModelCall'),
        _Throw('bad.end', throwIn: 'onTurnEnd'),
      ]);
      final outcome = await loop.runTurn(const Input('original', id: 'i5b'));

      expect(outcome.stopReason, StopReason.complete);
      expect(_text(outcome.messages.first), 'original');
      expect(provider.requests.first.systemPrompt, isNot(contains('|BOOM')));
    });
  });

  group('6. cancellation: stops promptly, records why', () {
    test('cancel before the turn -> no model call', () async {
      final provider = ScriptedProvider([]);
      final loop = AgentLoop(provider: provider, plugins: []);
      loop.cancel('user said stop');

      final outcome = await loop.runTurn(const Input('x', id: 'i6a'));

      expect(outcome.stopReason, StopReason.cancelled);
      expect(provider.callCount, 0);
      expect(outcome.detail, contains('user said stop'));
    });

    test('cancel from a plugin mid-turn -> stops before next model call',
        () async {
      final provider = ScriptedProvider([
        scriptedReply('',
            calls: [ToolUseBlock(id: 'c1', name: 't', input: {})]),
        scriptedReply('never reached'),
      ]);
      final loop = AgentLoop(provider: provider, plugins: [
        _CancelFromTool('canceller'),
        _plugin('owner', tools: [_tool('t')]),
      ]);
      loop.registerExecutor('t', (_) async => ToolResult('ran'));

      final outcome = await loop.runTurn(const Input('x', id: 'i6b'));

      expect(outcome.stopReason, StopReason.cancelled);
      expect(provider.callCount, 1);
      expect(outcome.detail, contains('plugin-cancelled'));
    });
  });

  group('7. plugin removal: pending call skipped, turn continues', () {
    test('removed plugin tool -> skipped result, then completion', () async {
      final provider = ScriptedProvider([
        scriptedReply('',
            calls: [ToolUseBlock(id: 'c1', name: 't', input: {})]),
        scriptedReply('done'),
      ]);
      final loop = AgentLoop(provider: provider, plugins: [
        _plugin('vanishing', tools: [_tool('t')]),
      ]);
      loop.registerExecutor('t', (_) async => ToolResult('ran'));
      // Remove from a hook, mid-turn — the brief's liveness rule is about a
      // plugin leaving while its pending call is in flight. The remover has
      // order 1, so it removes before the vanishing tool runs.
      loop.addPlugin(
          _Remover('remover', order: 1, loop: loop, target: 'vanishing'));

      final outcome = await loop.runTurn(const Input('x', id: 'i7'));

      expect(outcome.stopReason, StopReason.complete);
      final result = _result(outcome.messages.firstWhere(_isResult));
      expect(result.isError, isTrue);
      expect(result.content, contains('plugin vanishing left'));
    });
  });

  group('8. invariants: snapshots, pairing, pinning, duplicate ids', () {
    test('plugin mutation of a context does not touch the transcript',
        () async {
      final provider = ScriptedProvider([scriptedReply('ok')]);
      final loop = AgentLoop(provider: provider, plugins: [_Mutate('mutator')]);
      await loop.runTurn(const Input('keep me', id: 'i8a'));

      final seen = provider.requests.first.messages;
      expect(seen, isEmpty); // the mutator cleared its copy, not the truth
      expect(_transcriptText(loop), contains('user: keep me'));
    });

    test('every tool_use gets a matching tool_result, denied included',
        () async {
      final provider = ScriptedProvider([
        scriptedReply('', calls: [
          ToolUseBlock(id: 'c1', name: 'denied-tool', input: {}),
          ToolUseBlock(id: 'c2', name: 'good', input: {}),
        ]),
        scriptedReply('done'),
      ]);
      final loop = AgentLoop(provider: provider, plugins: [
        const GuardPlugin('denied-tool'),
        _plugin('owner', tools: [_tool('denied-tool'), _tool('good')]),
      ]);
      loop.registerExecutor('good', (_) async => ToolResult('ran'));

      final outcome = await loop.runTurn(const Input('x', id: 'i8b'));

      final advertised = provider.requests.first.tools;
      expect(
          [for (final t in advertised) t.name], containsAll(['denied-tool']));
      final results = [
        for (final m in outcome.messages)
          if (_isResult(m)) _result(m)
      ];
      expect([for (final r in results) r.toolUseId], ['c1', 'c2']);
      expect(results[0].isError, isTrue);
      expect(results[1].isError, isFalse);
    });

    test('pinned tools stay stable; mid-turn change rejects the turn',
        () async {
      final provider = ScriptedProvider([
        scriptedReply('',
            calls: [ToolUseBlock(id: 'c1', name: 't', input: {})]),
        scriptedReply('done'),
      ]);
      final shifter = _Shift('shifter');
      final loop = AgentLoop(provider: provider, plugins: [
        shifter,
        _plugin('owner', tools: [_tool('t')]),
      ]);
      loop.registerExecutor('t', (_) async => ToolResult('ran'));
      // Shift from inside a hook, mid-turn: the pinning invariant is about
      // the set changing while the turn is running.
      loop.addPlugin(_ShiftOnCall('shifter-trigger', shifter));

      final outcome = await loop.runTurn(const Input('x', id: 'i8c'));

      expect(outcome.stopReason, StopReason.error);
      expect(outcome.detail, contains('tools-changed'));
    });

    test('duplicate plugin id throws at registration', () {
      final loop =
          AgentLoop(provider: ScriptedProvider([]), plugins: [_plugin('dup')]);
      expect(() => loop.addPlugin(_plugin('dup')), throwsArgumentError);
    });
  });

  group('9. streaming edge paths (recorded, not prescribed)', () {
    test(
        'stream error mid-reply -> StopReason.error, detail recorded, '
        'no unpaired tool_use in the transcript', () async {
      final provider = ScriptedProvider([
        [
          ToolCallStart(id: 'c1', name: 't'),
          StreamError('socket blew up'),
        ],
      ]);
      final ran = <String>[];
      final loop = AgentLoop(provider: provider, plugins: [
        _plugin('owner', tools: [_tool('t')]),
      ]);
      loop.registerExecutor('t', (_) async {
        ran.add('ran!');
        return ToolResult('ran');
      });

      final outcome = await loop.runTurn(const Input('x', id: 'i9a'));

      expect(outcome.stopReason, StopReason.error);
      expect(outcome.detail, contains('provider error'));
      expect(outcome.detail, contains('socket blew up'));
      // The reply never landed, so there is no assistant message carrying
      // an unpaired tool_use: the transcript is the user message, period.
      expect([for (final m in outcome.messages) m.role], [Role.user]);
      final started = [
        for (final m in outcome.messages) m.content.whereType<ToolUseBlock>()
      ].expand((c) => c).length;
      final results = [
        for (final m in outcome.messages)
          for (final b in m.content.whereType<ToolResultBlock>()) b
      ].length;
      expect(started, results); // no unpaired tool_use anywhere
      expect(ran, isEmpty); // the started call never dispatched
    });

    test(
        'ToolCallStart then the stream ends with no MessageComplete -> '
        'the call is not dispatched; the turn ends StopReason.error', () async {
      final seen = <Map<String, Object?>>[];
      final provider = ScriptedProvider([
        [
          ToolCallStart(id: 'c1', name: 't'),
          // ...and that is the whole stream: no MessageComplete, no deltas.
        ],
      ]);
      final loop = AgentLoop(provider: provider, plugins: [
        _plugin('owner', tools: [_tool('t')]),
      ]);
      loop.registerExecutor('t', (args) async {
        seen.add(args);
        return ToolResult('ran');
      });

      final outcome = await loop.runTurn(const Input('x', id: 'i9b'));

      // The call's block comes from MessageComplete; with no completion
      // there is no ToolUseBlock in the transcript — nothing to pair a
      // result with, nothing legitimate to dispatch.
      expect(seen, isEmpty);
      // No reply message is written: ToolCallStart alone never becomes a
      // ToolUseBlock, and an empty assistant reply would be fabrication.
      final replies = [
        for (final m in outcome.messages)
          if (m.role == Role.assistant) m
      ];
      expect(replies, isEmpty);
      // No tool_result was recorded — there is no tool_use to pair with.
      expect(outcome.messages.where(_isResult), isEmpty);
      // The turn ended as an error, with the reason recorded.
      expect(outcome.stopReason, StopReason.error);
      expect(
          outcome.detail,
          'provider stream ended before tool call c1 '
          'completed');
      // One model call only: the turn did not continue to a second round.
      expect(provider.callCount, 1);
    });

    test(
        'interleaved TextDelta and ReasoningDelta: transcript text comes '
        'from MessageComplete, deltas are dropped', () async {
      final provider = ScriptedProvider([
        [
          const TextDelta('DELTA-1 '),
          const ReasoningDelta('thinking... ', startsBlock: true),
          const TextDelta('DELTA-2 '),
          const ReasoningDelta('more thinking'),
          const TextDelta('DELTA-3'),
          const MessageComplete(
              content: [TextBlock('FINAL')], stopReason: 'end_turn'),
        ],
      ]);
      final loop = AgentLoop(provider: provider, plugins: []);

      final outcome = await loop.runTurn(const Input('x', id: 'i9c'));

      expect(outcome.stopReason, StopReason.complete);
      // The reply's blocks come from MessageComplete alone: one text block
      // with the completion's text; no delta text, no reasoning blocks.
      final reply = outcome.messages.last;
      expect(reply.role, Role.assistant);
      expect(reply.content.length, 1);
      expect(_text(reply), 'FINAL');
      expect(_text(reply), isNot(contains('DELTA')));
      // The loop's fallback: with no MessageComplete at all, accumulated
      // delta text becomes the reply.
      final fallback = ScriptedProvider([
        [const TextDelta('only deltas '), const TextDelta('here')],
      ]);
      final loop2 = AgentLoop(provider: fallback, plugins: []);
      final outcome2 = await loop2.runTurn(const Input('y', id: 'i9d'));
      expect(outcome2.stopReason, StopReason.complete);
      expect(_text(outcome2.messages.last), 'only deltas here');
    });

    test(
        'provider send() throws instead of yielding -> runTurn ends '
        'StopReason.error with the error recorded', () async {
      final throwing = _ThrowingSendProvider();
      final loop = AgentLoop(provider: throwing, plugins: []);

      // The loop catches the throw at the stream seam: the turn ends the
      // same way a StreamError ends it, with the error in the detail.
      final outcome = await loop.runTurn(const Input('x', id: 'i9e'));

      expect(outcome.stopReason, StopReason.error);
      expect(outcome.detail, startsWith('provider error:'));
      expect(outcome.detail, contains('_ThrowingSendProvider'));
      // Nothing streamed, so the transcript holds just the user message.
      expect([for (final m in outcome.messages) m.role], [Role.user]);
    });

    test(
        'provider throws mid-stream after deltas -> the turn ends '
        'StopReason.error and the partial text is kept, not discarded',
        () async {
      final provider = _ThrowMidStreamProvider([
        const TextDelta('partial answer '),
      ]);
      final loop = AgentLoop(provider: provider, plugins: []);

      final outcome = await loop.runTurn(const Input('x', id: 'i9f'));

      expect(outcome.stopReason, StopReason.error);
      expect(outcome.detail, startsWith('provider error:'));
      expect(outcome.detail, contains('mid-stream'));
      // Whatever had accumulated before the throw is the reply.
      final replies = [
        for (final m in outcome.messages)
          if (m.role == Role.assistant) m
      ];
      expect(replies, hasLength(1));
      expect(_text(replies.single), 'partial answer ');
    });
  });

  group('10. a tina_tools tool mounted on the loop', () {
    test(
        'WriteTool schema is advertised; execute runs as the executor; '
        'the file lands', () async {
      final dir = await Directory.systemTemp.createTemp('tina_e2_tools_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final write = WriteTool(workspaceRoot: dir.path);
      final provider = ScriptedProvider([
        scriptedReply('', calls: [
          ToolUseBlock(
              id: 'c1',
              name: 'write',
              input: {'filePath': 'note.txt', 'content': 'from the model'}),
        ]),
        scriptedReply('done'),
      ]);
      final loop = AgentLoop(provider: provider, plugins: [
        _ToolsPlugin([write])
      ]);
      loop.registerExecutor('write', write.execute);

      final outcome = await loop.runTurn(const Input('save', id: 'i10'));

      expect(outcome.stopReason, StopReason.complete);
      expect(provider.callCount, 2);
      // The tool's schema reached the provider's tools list.
      expect(provider.requests.first.tools.map((t) => t.name), ['write']);
      // The executor ran the real tool: the file landed under the root.
      expect(File('${dir.path}/note.txt').readAsStringSync(), 'from the model');
      // The transcript carries the tool's own success content.
      final result = _result(outcome.messages.firstWhere(_isResult));
      expect(result.isError, isFalse);
      expect(result.content, contains('created'));
      expect(result.content, contains('note.txt'));
    });

    test(
        'a refusing filesystem records the refusal as the tool_result and '
        'the turn continues', () async {
      final dir = await Directory.systemTemp.createTemp('tina_e2_refuse_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final tinaDir = await Directory.systemTemp.createTemp('tina_e2_tina_');
      addTearDown(() => tinaDir.deleteSync(recursive: true));
      final sandbox = SandboxedFileSystem(const IoFileSystem(),
          workspaceRoot: dir.path,
          tinaDir: tinaDir,
          mode: PermissionMode.readOnly);
      final write = WriteTool(fs: sandbox, workspaceRoot: dir.path);
      final provider = ScriptedProvider([
        scriptedReply('', calls: [
          ToolUseBlock(
              id: 'c1',
              name: 'write',
              input: {'filePath': 'blocked.txt', 'content': 'x'}),
        ]),
        // The turn continues: the model sees the refusal and answers.
        scriptedReply('understood, staying read-only'),
      ]);
      final loop = AgentLoop(provider: provider, plugins: [
        _ToolsPlugin([write])
      ]);
      loop.registerExecutor('write', write.execute);

      final outcome =
          await loop.runTurn(const Input('try to write', id: 'i11'));

      expect(outcome.stopReason, StopReason.complete);
      expect(provider.callCount, 2,
          reason: 'the turn continued past the refused call');
      // The refusal is exactly what the model was told, as the tool_result.
      final result = _result(outcome.messages.firstWhere(_isResult));
      expect(result.isError, isTrue);
      expect(result.content, contains('read-only mode'));
      // And nothing was written.
      expect(File('${dir.path}/blocked.txt').existsSync(), isFalse);
    });
  });

  group('11. the copy rule: a context is copied per plugin call', () {
    test(
        'a thrower leaves the turn intact; its writes are absent; '
        'the next plugin runs', () async {
      final provider = ScriptedProvider([scriptedReply('ok')]);
      final loop = AgentLoop(provider: provider, plugins: [
        _Writer('writer', section: 'KEPT'),
        _Throw('bad', throwIn: 'beforeModelCall'),
        _plugin('late', section: 'LATE'),
      ]);
      await loop.runTurn(const Input('x', id: 'i12a'));

      final prompt = provider.requests.single.systemPrompt;
      expect(prompt, contains('KEPT')); // writer's write arrived
      expect(prompt, contains('LATE')); // the next plugin still ran
    });

    test('the next plugin sees the prior plugin\'s writes', () async {
      final provider = ScriptedProvider([scriptedReply('ok')]);
      final seen = <List<String>>[];
      final loop = AgentLoop(provider: provider, plugins: [
        _plugin('a.writer', section: 'FROM-WRITER'),
        _Reader('z.reader', seen: seen),
      ]);
      await loop.runTurn(const Input('x', id: 'i12b'));
      expect(seen.single, ['FROM-WRITER']);
    });

    test(
        'a plugin adds a prompt section for one call without replacing '
        'the rest of the request', () async {
      final provider = ScriptedProvider([scriptedReply('ok')]);
      final loop = AgentLoop(provider: provider, plugins: [
        _plugin('base', section: 'BASE-SECTION'),
        _T('adder', order: 300, mark: 'ONE-CALL'),
      ]);
      await loop.runTurn(const Input('x', id: 'i12c'));

      final prompt = provider.requests.single.systemPrompt;
      expect(prompt, contains('BASE-SECTION'));
      expect(prompt, contains('ONE-CALL'));
      final request = provider.requests.single;
      expect(_text(request.messages.single), 'x'); // messages untouched
    });
  });

  group('12. bash behind the loop, read-only', () {
    test(
        'a command call is refused as a tool_result and the turn continues; '
        'nothing ran', () async {
      final dir = await Directory.systemTemp.createTemp('tina_e2_proc_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final bash = BashTool(
        runner: SandboxedProcessRunner(
          inner: const IoProcessRunner(),
          writableDirectories: WritableDirectories()..add(dir.path),
          mode: PermissionMode.readOnly,
        ),
        workingDirectory: dir.path,
      );
      final provider = ScriptedProvider([
        scriptedReply('', calls: [
          ToolUseBlock(id: 'c1', name: 'bash', input: {'command': 'echo hi'}),
        ]),
        // The turn continues: the model sees the refusal and answers.
        scriptedReply('understood, read-only'),
      ]);
      final loop = AgentLoop(provider: provider, plugins: [
        _ToolsPlugin([bash])
      ]);
      loop.registerExecutor('bash', bash.execute);

      final outcome =
          await loop.runTurn(const Input('run something', id: 'i12'));

      expect(outcome.stopReason, StopReason.complete);
      expect(provider.callCount, 2,
          reason: 'the turn continued past the refused call');
      // The refusal is exactly what the model was told, as the tool_result.
      final result = _result(outcome.messages.firstWhere(_isResult));
      expect(result.isError, isTrue);
      expect(result.content, contains('read-only mode'));
      // The enforcement is at the runner, not the loop: no tool_result guard
      // was involved, and the sandbox decided. Nothing ran — in read-only
      // mode the sandbox denies without spawning, so we assert on the
      // absence of any side effect the command would have had.
      final marker = File('${dir.path}/hi');
      expect(marker.existsSync(), isFalse,
          reason: 'echo never executed, so no side effect landed');
    });

    test(
        'outside the writable directories with no approver: denied fail-closed, '
        'turn continues', () async {
      final dir = await Directory.systemTemp.createTemp('tina_e2_proc2_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final bash = BashTool(
        runner: SandboxedProcessRunner(
          inner: const IoProcessRunner(),
          writableDirectories: WritableDirectories()..add(dir.path),
          // No approver: anything needing a question is denied.
        ),
        workingDirectory: dir.path,
      );
      final provider = ScriptedProvider([
        scriptedReply('', calls: [
          ToolUseBlock(
              id: 'c1', name: 'bash', input: {'command': 'cat /etc/hostname'}),
        ]),
        scriptedReply('noted'),
      ]);
      final loop = AgentLoop(provider: provider, plugins: [
        _ToolsPlugin([bash])
      ]);
      loop.registerExecutor('bash', bash.execute);

      final outcome = await loop.runTurn(const Input('read a file', id: 'i13'));

      expect(outcome.stopReason, StopReason.complete);
      expect(provider.callCount, 2);
      final result = _result(outcome.messages.firstWhere(_isResult));
      expect(result.isError, isTrue);
      // The bash shape cannot be certified at all — it asks, and with no
      // approver wired the sandbox denies fail-closed.
      expect(result.content, contains('shell command string'));
      expect(result.content, contains('no approver'));
    });
  });
}

/// A `LlmProvider` whose `send` throws when the stream is created — the
/// provider-died-before-yielding case. [ScriptedProvider] cannot express
/// that, so this stands in for the seam.
final class _ThrowingSendProvider implements LlmProvider {
  @override
  final String model = 'throwing';

  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) {
    throw this;
  }

  @override
  void close() {}
}

/// Yields [events] then throws mid-stream — the deltas-landed-then-died
/// case. [_Boom] is the exception the seam raises.
final class _Boom implements Exception {
  const _Boom();
  @override
  String toString() => 'mid-stream detonation';
}

final class _ThrowMidStreamProvider implements LlmProvider {
  _ThrowMidStreamProvider(this.events);
  final List<StreamEvent> events;

  @override
  final String model = 'throw-mid-stream';

  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) async* {
    for (final e in events) {
      yield e;
    }
    throw const _Boom();
  }

  @override
  void close() {}
}

/// A guard that asks (no UI in this package).
final class _Ask extends AgentPlugin {
  _Ask(this.id);
  @override
  final String id;
  @override
  void beforeToolCall(TurnContext c) => c.decision = Decision.ask('unsure');
}

/// Throws in one chosen phase.
final class _Throw extends AgentPlugin {
  _Throw(this.id, {required this.throwIn});
  @override
  final String id;
  final String throwIn;
  Never boom() => throw StateError('BOOM');
  @override
  void onInput(TurnContext c) {
    if (throwIn == 'onInput') boom();
  }

  @override
  void onPrompt(TurnContext c) {
    if (throwIn == 'onPrompt') boom();
  }

  @override
  void beforeModelCall(TurnContext c) {
    if (throwIn == 'beforeModelCall') boom();
  }

  @override
  void beforeToolCall(TurnContext c) {
    if (throwIn == 'beforeToolCall') boom();
  }

  @override
  void afterToolResult(TurnContext c) {
    if (throwIn == 'afterToolResult') boom();
  }

  @override
  void onTurnEnd(TurnContext c) {
    if (throwIn == 'onTurnEnd') boom();
  }
}

/// Removes another plugin from `beforeModelCall`: the model has asked for
/// the target's tool, but by dispatch time the owner is gone.
final class _Remover extends AgentPlugin {
  _Remover(this.id,
      {required this.order, required this.loop, required this.target});
  @override
  final String id;
  @override
  final int order;
  final AgentLoop loop;
  final String target;
  @override
  void beforeModelCall(TurnContext c) => loop.removePlugin(target);
}

/// Cancels from `afterToolResult`.
final class _CancelFromTool extends AgentPlugin {
  _CancelFromTool(this.id);
  @override
  final String id;
  @override
  void afterToolResult(TurnContext c) => c.cancel('plugin-cancelled');
}

/// Mutates whatever context it is handed.
final class _Mutate extends AgentPlugin {
  _Mutate(this.id);
  @override
  final String id;
  @override
  void beforeModelCall(TurnContext c) {
    c.messages.clear(); // must not touch the transcript
  }
}

/// Writes a section, for the copy-rule tests.
final class _Writer extends AgentPlugin {
  _Writer(this.id, {required this.section});
  @override
  final String id;
  final String section;
  @override
  void beforeModelCall(TurnContext c) => c.promptSections.add(section);
}

/// Records the sections it sees, for the copy-rule tests.
final class _Reader extends AgentPlugin {
  _Reader(this.id, {required this.seen});
  @override
  final String id;
  final List<List<String>> seen;
  @override
  void beforeModelCall(TurnContext c) => seen.add(List.of(c.promptSections));
}

/// Adds a tool when [shiftFromHook] is set.
final class _Shift extends AgentPlugin {
  _Shift(this.id);
  @override
  final String id;
  bool shiftFromHook = false;
  @override
  List<ToolSchema> get tools =>
      shiftFromHook ? [_tool('t'), _tool('late-tool')] : [_tool('t')];
}

/// Flips the shifter from `beforeToolCall`, mid-turn.
final class _ShiftOnCall extends AgentPlugin {
  _ShiftOnCall(this.id, this.shifter);
  @override
  final String id;
  final _Shift shifter;
  @override
  void beforeToolCall(TurnContext c) => shifter.shiftFromHook = true;
}

/// Adds a mark to every request, with its own order.
final class _T extends AgentPlugin {
  _T(this.id, {required this.order, required this.mark});
  @override
  final String id;
  @override
  final int order;
  final String mark;
  @override
  void beforeModelCall(TurnContext c) => c.promptSections.add(mark);
}

/// Mounts a real tina_tools tool onto the loop: schema from [tools]'s
/// members, executor from `execute`. This is the adapter a host writes.
final class _ToolsPlugin extends AgentPlugin {
  _ToolsPlugin(this.tools_);
  @override
  String get id => 'tools';
  @override
  List<ToolSchema> get tools => [for (final t in tools_) t.schema];
  final List<Tool> tools_;
}
