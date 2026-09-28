/// The sub-agents battery — the brief's cases, one `test()` each.
///
/// Everything runs through the real pieces: a parent [Host] whose loop
/// dispatches `spawn_subagent` to the plugin, which builds a child
/// [Host] via [Host.child] + [standardChildFactory]; the scripted
/// provider plays the model on both sides. The exception is the
/// cancellation case, whose child needs a provider that never completes
/// — [StallingProvider] — because a scripted queue always ends.
library;

import 'dart:async';
import 'dart:io';

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_subagents/tina_subagents.dart';
import 'package:tina_tools/tina_tools.dart';
import 'package:test/test.dart';

import 'harness.dart';

/// A provider whose stream emits one delta and then never completes —
/// the only way a turn stays in flight for a cancel to catch. The
/// loop's `send` await ends when the stream is cancelled out from under
/// it, which the child loop's own cancel does.
final class StallingProvider implements LlmProvider {
  @override
  final String model = 'stalling';

  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) async* {
    yield const TextDelta('working…');
    // Never completes on its own; cancelling the loop cancels the
    // turn's await and the stream is dropped.
    await Completer<void>().future;
  }

  @override
  void close() {}
}

/// One scripted model reply, optionally carrying the usage the loop
/// books into the turn's end entry — the hook the sub-agents counters
/// read.
List<StreamEvent> scriptedTurn(String text,
    {List<ToolUseBlock> calls = const [], TokenUsage? usage}) => [
      for (final c in calls) ToolCallStart(id: c.id, name: c.name),
      MessageComplete(
        content: [if (text.isNotEmpty) TextBlock(text), ...calls],
        stopReason: calls.isEmpty ? 'end_turn' : 'tool_use',
        usage: usage,
      ),
    ];

void main() {
  test('a child runs a turn with the scripted provider; its final text '
      'is the tool result', () async {
    final ws = workspace();
    final h = harness(
      dir: ws.dir,
      scripts: [
        // Parent: asks for a spawn.
        [
          scriptedReply('', calls: [
            ToolUseBlock(
                id: 'c1',
                name: 'spawn_subagent',
                input: {'prompt': 'summarize the workspace'}),
          ]),
        ],
        // Child: answers, no tool calls — the turn ends there.
        [scriptedReply('the workspace is quiet')],
        // Parent: takes the result and finishes.
        [scriptedReply('done')],
      ],
    );
    final o = await h.host.send('spawn a sub-agent');
    expect(o.stopReason, StopReason.complete);
    expect(h.plugin.parent.details.childrenInFlight, 0);
    final resultText = o.messages
        .expand((m) => m.content)
        .whereType<ToolResultBlock>()
        .map((b) => b.content)
        .join('\n');
    expect(resultText, contains('the workspace is quiet'));
    expect(resultText, contains('[sub-agent ${h.plugin.parent.id}-child1]'));
    // Each host builds its own provider once: the parent's serves both
    // of its turns, the child's exactly one. No sharing — two providers
    // built in all.
    expect(h.providers, hasLength(2));
    expect(h.providers[0].callCount, 2);
    expect(h.providers[1].callCount, 1);
    h.host.close();
    h.dir.deleteSync(recursive: true);
  });

  test('a child at the maximum depth is refused, and the refusal names '
      'depth', () async {
    final ws = workspace();
    // A parent already AT the depth limit: its children would sit at
    // maxDepth+1.
    final h = harness(
      dir: ws.dir,
      config: const SubagentsConfig(maxDepth: 3),
      scripts: [
        [
          scriptedReply('', calls: [
            ToolUseBlock(
                id: 'c1',
                name: 'spawn_subagent',
                input: {'prompt': 'go deeper'}),
          ]),
        ],
        [scriptedReply('parent done')],
      ],
    );
    h.host.session.details.depth = 3;
    final r = await h.plugin.spawn('anything');
    expect(r.isError, isTrue);
    expect(r.content, contains('depth 4 exceeds maximum 3'));
    // No child was ever built: only the parent's provider exists.
    expect(h.providers, hasLength(1));
    h.host.close();
    h.dir.deleteSync(recursive: true);
  });

  test('concurrency at the maximum is refused, and the refusal names '
      'concurrency', () async {
    final ws = workspace();
    final h = harness(
      dir: ws.dir,
      config: const SubagentsConfig(maxConcurrency: 1),
      scripts: const [],
    );
    // One slot busy, as another spawn in flight would leave it.
    h.plugin.parent.details.childrenInFlight = 1;
    final r = await h.plugin.spawn('anything');
    expect(r.isError, isTrue);
    expect(r.content, contains('concurrency at maximum 1'));
    h.host.close();
    h.dir.deleteSync(recursive: true);
  });

  test('the token budget being exhausted is refused, and the refusal '
      'names the budget', () async {
    final ws = workspace();
    final h = harness(
      dir: ws.dir,
      config: const SubagentsConfig(tokenBudget: 100),
      scripts: const [],
    );
    h.plugin.budget.add(100);
    final r = await h.plugin.spawn('anything');
    expect(r.isError, isTrue);
    expect(r.content, contains('token budget exhausted'));
    expect(r.content, contains('spent 100 of limit 100'));
    h.host.close();
    h.dir.deleteSync(recursive: true);
  });

  test('cancelling the parent\'s turn cancels the child', () async {
    final ws = workspace();
    final h = harness(
      dir: ws.dir,
      scripts: [
        // Parent: spawns.
        [
          scriptedReply('', calls: [
            ToolUseBlock(
                id: 'c1',
                name: 'spawn_subagent',
                input: {'prompt': 'long work'}),
          ]),
        ],
      ],
      childProvider: StallingProvider(),
    );
    final turn = h.host.send('go');
    // Wait for the child to actually be in flight, then cancel the
    // parent's turn.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(h.plugin.parent.details.childrenInFlight, 1);
    h.host.session.loop.cancel('test cancel');
    final o = await turn;
    expect(o.stopReason, StopReason.cancelled);
    // The child settled through the passthrough; the slot is free.
    expect(h.plugin.parent.details.childrenInFlight, 0);
    h.host.close();
    h.dir.deleteSync(recursive: true);
  });

  test('the child cannot escalate the mode: a read-only parent denies '
      'a write in the child, never asked', () async {
    final ws = workspace();
    final h = harness(
      dir: ws.dir,
      mode: PermissionMode.readOnly,
      scripts: [
        [
          scriptedReply('', calls: [
            ToolUseBlock(
                id: 'c1',
                name: 'spawn_subagent',
                input: {
                  'prompt': 'write escape.txt with the write tool',
                }),
          ]),
        ],
        // Child tries a write; the boundary denies without asking.
        [
          scriptedReply('', calls: [
            ToolUseBlock(
                id: 'w1',
                name: 'write',
                input: {'filePath': 'escape.txt', 'content': 'nope'}),
          ]),
        ],
        [scriptedReply('child saw the denial')],
        [scriptedReply('parent done')],
      ],
    );
    // An approver IS wired on the parent's boundary — and must never be
    // consulted by the child's: read-only denies outright, never asks.
    var asked = false;
    h.tools.sandbox.approver = (request, reason) async {
      asked = true;
      return Approval.no;
    };
    final o = await h.host.send('try to escape');
    expect(o.stopReason, StopReason.complete);
    expect(asked, isFalse, reason: 'a read-only child must never ask');
    expect(File('${ws.dir.path}/escape.txt').existsSync(), isFalse);
    h.host.close();
    h.dir.deleteSync(recursive: true);
  });

  test('the child\'s writes go through the same sandbox', () async {
    final ws = workspace();
    final h = harness(
      dir: ws.dir,
      scripts: [
        [
          scriptedReply('', calls: [
            ToolUseBlock(
                id: 'c1',
                name: 'spawn_subagent',
                input: {'prompt': 'write a file inside the workspace'}),
          ]),
        ],
        [
          scriptedReply('', calls: [
            ToolUseBlock(
                id: 'w1',
                name: 'write',
                input: {'filePath': 'inside.txt', 'content': 'from the child'}),
          ]),
        ],
        [scriptedReply('wrote it')],
        [scriptedReply('parent done')],
      ],
    );
    // No approver: in normal mode an in-workspace write runs without
    // one; an escape would fail closed. The child's write lands inside
    // the same workspace root the parent's tools guard.
    await h.host.send('write via child');
    expect(
        File('${ws.dir.path}/inside.txt').readAsStringSync(), 'from the child');
    h.host.close();
    h.dir.deleteSync(recursive: true);
  });

  test('the child\'s log is separate, and resumable on its own',
      () async {
    final ws = workspace();
    final storePath = '${ws.dir.path}/store.db';
    final h = harness(
      dir: ws.dir,
      storePath: storePath,
      scripts: [
        [
          scriptedReply('', calls: [
            ToolUseBlock(
                id: 'c1',
                name: 'spawn_subagent',
                input: {'prompt': 'remember the word basilisk'}),
          ]),
        ],
        [scriptedReply('the word is basilisk')],
        [scriptedReply('parent done')],
      ],
    );
    await h.host.send('go');
    h.host.close();
    // The child's session exists in the store under its own id, with
    // its own conversation — resumable on its own.
    final store = SessionStore.open(storePath);
    final ids = store.list().map((s) => s.id).toList();
    final childId = ids.where((i) => i.endsWith('-child1')).single;
    expect(ids, contains(childId));
    store.close();
    final resumed = Host.resume(
      HostConfig(
        providerFactory: (model) => ScriptedProvider(const []),
        workingDirectory: ws.dir.path,
        plugins: const [],
        storePath: storePath,
      ),
      childId,
    );
    expect(
        resumed.session.loop.log.whereType<InputRecordedEntry>().single.text,
        'remember the word basilisk');
    // The reply derives from the resumed log's last assistant message —
    // `lastReply` reads in-memory turns, which a fresh resume has none
    // of.
    final resumedReply = resumed.session.loop.log
        .whereType<MessageAppendedEntry>()
        .map((e) => e.message)
        .where((m) => m.role == Role.assistant)
        .map((m) => [
              for (final b in m.content.whereType<TextBlock>()) b.text
            ].join())
        .last;
    expect(resumedReply, 'the word is basilisk');
    resumed.close();
    h.host.close();
    h.dir.deleteSync(recursive: true);
  });

  test('the parent\'s log holds the tool call and the child\'s answer, '
      'and not the child\'s messages', () async {
    final ws = workspace();
    final storePath = '${ws.dir.path}/store.db';
    final h = harness(
      dir: ws.dir,
      storePath: storePath,
      scripts: [
        [
          scriptedReply('', calls: [
            ToolUseBlock(
                id: 'c1',
                name: 'spawn_subagent',
                input: {'prompt': 'inner prompt one'}),
          ]),
        ],
        [scriptedReply('child final answer')],
        [scriptedReply('parent wrap-up')],
      ],
    );
    await h.host.send('go');
    h.host.close();
    final store = SessionStore.open(storePath);
    final parentEntries = store.readEntries(h.plugin.parent.id);
    final childIds = store
        .list()
        .map((s) => s.id)
        .where((i) => i != h.plugin.parent.id)
        .toList();
    store.close();
    // The parent's log: the tool call with the prompt, the result with
    // the child's answer.
    final calls = parentEntries
        .whereType<MessageAppendedEntry>()
        .expand((e) => e.message.content)
        .whereType<ToolUseBlock>()
        .where((b) => b.name == 'spawn_subagent')
        .toList();
    expect(calls, hasLength(1));
    expect(calls.single.input['prompt'], 'inner prompt one');
    final results = parentEntries
        .whereType<MessageAppendedEntry>()
        .expand((e) => e.message.content)
        .whereType<ToolResultBlock>()
        .map((b) => b.content)
        .join('\n');
    expect(results, contains('child final answer'));
    // And nothing of the child's transcript rides in the parent's log:
    // exactly one user input — the parent's own.
    final parentTexts =
        parentEntries.whereType<InputRecordedEntry>().map((e) => e.text);
    expect(parentTexts, ['go']);
    expect(childIds, hasLength(1));
    h.dir.deleteSync(recursive: true);
  });

  test('depth, children in flight and tokens spent survive a store '
      'round trip', () async {
    final ws = workspace();
    final storePath = '${ws.dir.path}/store.db';
    final h = harness(
      dir: ws.dir,
      storePath: storePath,
      scripts: [
        [
          scriptedReply('', calls: [
            ToolUseBlock(
                id: 'c1',
                name: 'spawn_subagent',
                input: {'prompt': 'count something'}),
          ]),
        ],
        [
          scriptedTurn('child counts to three',
              usage: const TokenUsage(inputTokens: 11, outputTokens: 7)),
        ],
        [scriptedReply('parent done')],
      ],
    );
    await h.host.send('go');
    // The child's usage booked; save persists the counters.
    expect(h.plugin.parent.details.tokensSpent, 18);
    h.host.saveDetails();
    h.host.close();
    final store = SessionStore.open(storePath);
    final details = store.readDetails(h.plugin.parent.id);
    store.close();
    expect(details.depth, 0);
    expect(details.childrenInFlight, 0);
    expect(details.tokensSpent, 18);
    // A resumed host reads the same numbers.
    final resumed = Host.resume(
      HostConfig(
        providerFactory: (model) => ScriptedProvider(const []),
        workingDirectory: ws.dir.path,
        plugins: const [],
        storePath: storePath,
      ),
      h.plugin.parent.id,
    );
    expect(resumed.session.details.tokensSpent,
        h.plugin.parent.details.tokensSpent);
    resumed.close();
    h.host.close();
    h.dir.deleteSync(recursive: true);
  });

  test('usage from the child books into the parent\'s tokens spent and '
      'the shared gate', () async {
    final ws = workspace();
    final h = harness(
      dir: ws.dir,
      scripts: [
        [
          scriptedReply('', calls: [
            ToolUseBlock(
                id: 'c1',
                name: 'spawn_subagent',
                input: {'prompt': 'do work'}),
          ]),
        ],
        [
          scriptedTurn('child work done',
              usage: const TokenUsage(inputTokens: 30, outputTokens: 12)),
        ],
        [scriptedReply('parent done')],
      ],
    );
    await h.host.send('go');
    expect(h.plugin.parent.details.tokensSpent, 42);
    expect(h.plugin.budget.spent, 42);
    h.dir.deleteSync(recursive: true);
  });

  test('a child of a child is refused at the configured depth',
      () async {
    final ws = workspace();
    final storePath = '${ws.dir.path}/store.db';
    final h = harness(
      dir: ws.dir,
      storePath: storePath,
      config: const SubagentsConfig(maxDepth: 1),
      scripts: [
        // Parent (depth 0): spawns a child — allowed, the child sits at 1.
        [
          scriptedReply('', calls: [
            ToolUseBlock(
                id: 'c1',
                name: 'spawn_subagent',
                input: {'prompt': 'you may spawn no further'}),
          ]),
        ],
        // The child (depth 1) asks to spawn; the default factory gives
        // it no sub-agents plugin, so the call has no executor.
        [
          scriptedReply('', calls: [
            ToolUseBlock(
                id: 'c2',
                name: 'spawn_subagent',
                input: {'prompt': 'too deep'}),
          ]),
        ],
        [scriptedReply('child finished anyway')],
        [scriptedReply('parent done')],
      ],
    );
    final o = await h.host.send('go');
    expect(o.stopReason, StopReason.complete);
    // The refusal rides back in the child's second tool result, and the
    // child's own log records it — the spawn never ran, so the store
    // holds exactly two sessions and no grandchild.
    final store = SessionStore.open(storePath);
    final ids = store.list().map((s) => s.id).toList();
    final childId = ids.where((i) => i.endsWith('-child1')).single;
    final childEntries = store.readEntries(childId);
    store.close();
    final childResults = childEntries
        .whereType<MessageAppendedEntry>()
        .expand((e) => e.message.content)
        .whereType<ToolResultBlock>()
        .map((b) => b.content);
    expect(childResults, contains('no executor for spawn_subagent'));
    expect(ids.where((i) => i.endsWith('-child2')), isEmpty,
        reason: 'a grandchild was never built');
    expect(ids.where((i) => i.endsWith('child1-child1')), isEmpty);
    expect(childId, startsWith('${h.plugin.parent.id}-child'));
    // The same shape, driven directly: a plugin bound to a session that
    // already sits at the maximum refuses before building anything.
    final childHost = Host.resume(
      HostConfig(
        providerFactory: (model) => ScriptedProvider(const []),
        workingDirectory: ws.dir.path,
        plugins: const [],
        storePath: storePath,
      ),
      childId,
    );
    final deepPlugin = SubagentsPlugin(
      parent: childHost.session,
      config: const SubagentsConfig(maxDepth: 1),
      sessionFactory: standardChildFactory(
        parentTools: ToolsPlugin(
          workspaceRoot: ws.dir.path,
          tinaDir: Directory('${ws.dir.path}/.tina'),
          mode: PermissionMode.normal,
          osSandbox: false,
        ),
        providerFactory: (model) => ScriptedProvider(const []),
      ),
    );
    final r = await deepPlugin.spawn('too deep');
    expect(r.isError, isTrue);
    expect(r.content, contains('depth 2 exceeds maximum 1'));
    childHost.close();
    h.host.close();
    h.dir.deleteSync(recursive: true);
  });
}
