/// The sub-agents battery — the brief's cases, one `test()` each.
///
/// Everything runs through the real pieces: a parent [Host] whose loop
/// dispatches `launch_subagent`/`subagent` to the plugin, which builds a
/// child [Host] via [Host.child] + [standardChildFactory]; the scripted
/// provider plays the model on both sides. A launch is **non-blocking**:
/// the tool returns immediately with the child's id, and the child runs
/// in the background — tests follow it with `inspect` (`wait`/`cancel`).
///
/// Parent model turns come from `scripts`; child turns from
/// `childScripts` (see [harness]) — a child's background turns never race
/// the parent's model calls. The exception is the cancellation case,
/// whose child needs a provider that never completes — [StallingProvider]
/// — because a scripted queue always ends.
library;

import 'package:tina_persistence/tina_persistence.dart';
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
        {List<ToolUseBlock> calls = const [], TokenUsage? usage}) =>
    [
      for (final c in calls) ToolCallStart(id: c.id, name: c.name),
      MessageComplete(
        content: [if (text.isNotEmpty) TextBlock(text), ...calls],
        stopReason: calls.isEmpty ? 'end_turn' : 'tool_use',
        usage: usage,
      ),
    ];

/// A [SubagentHistorySource] over a session store, for the resurrection
/// test — the same shape the application wires in plugin_catalog.
final class _TestHistory implements SubagentHistorySource {
  _TestHistory(this._open);
  final SessionStore Function() _open;

  @override
  Map<String, String?> storedSessions() {
    final store = _open();
    try {
      final out = <String, String?>{};
      for (final session in store.list()) {
        String? last;
        for (final entry in store.readEntries(session.id)) {
          if (entry is MessageAppendedEntry) {
            final text = [
              for (final b in entry.message.content.whereType<TextBlock>())
                b.text,
            ].join();
            if (text.isNotEmpty) last = text;
          }
        }
        out[session.id] = last;
      }
      return out;
    } finally {
      store.close();
    }
  }
}

void main() {
  test('launch is non-blocking; wait retrieves the child\'s final text',
      () async {
    final ws = workspace();
    final h = harness(
      dir: ws.dir,
      scripts: [
        // Parent: asks for a launch, then finishes without waiting.
        [
          scriptedReply('', calls: [
            ToolUseBlock(
                id: 'c1',
                name: 'launch_subagent',
                input: {'prompt': 'summarize the workspace'}),
          ]),
        ],
        [
          scriptedReply('parent done'),
        ],
      ],
      childScripts: [
        // Child: answers, no tool calls — the turn ends there.
        [scriptedReply('the workspace is quiet')],
      ],
    );
    final o = await h.host.send('launch a sub-agent');
    expect(o.stopReason, StopReason.complete);
    final id = h.plugin.launchedChildIds.single;
    // The launch result named the id immediately; the parent did not wait
    // for the child.
    final launchResults = o.messages
        .expand((m) => m.content)
        .whereType<ToolResultBlock>()
        .map((b) => b.content)
        .join('\n');
    expect(launchResults, contains('launched sub-agent $id'));
    // The child ran to completion on its own; wait returns its final text.
    final r = await h.plugin.inspect(id, action: 'wait');
    expect(r.isError, isFalse);
    expect(r.content, startsWith('[sub-agent $id]'));
    expect(r.content, contains('the workspace is quiet'));
    expect(h.plugin.childrenInFlight, 0);
    h.host.close();
    h.dir.deleteSync(recursive: true);
  });

  test('child provider failure marks the launch\'s result as an error',
      () async {
    final h = harness(
      scripts: [
        [
          scriptedReply('', calls: [
            const ToolUseBlock(
                id: 'spawn',
                name: 'launch_subagent',
                input: {'prompt': 'inspect files'})
          ]),
        ],
        [scriptedReply('parent done')],
      ],
      childScripts: [
        [
          [const StreamError('child provider unavailable')]
        ],
      ],
    );
    addTearDown(() {
      h.host.close();
      h.dir.deleteSync(recursive: true);
    });
    await h.host.send('delegate');
    final id = h.plugin.launchedChildIds.single;
    final r = await h.plugin.inspect(id, action: 'wait');
    expect(r.isError, true);
    expect(r.content, contains('sub-agent'));
    expect(h.plugin.childrenInFlight, 0);
  });

  test('a child at the maximum depth is refused, and the refusal names '
      'depth', () async {
    final ws = workspace();
    final h = harness(
      dir: ws.dir,
      config: const SubagentsConfig(maxDepth: 3),
      scripts: const [],
    );
    h.host.session.details.depth = 3;
    final r = h.plugin.launch('anything');
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
    // One slot busy, as another launch in flight would leave it.
    h.plugin.parent.details.childrenInFlight = 1;
    final r = h.plugin.launch('anything');
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
    final r = h.plugin.launch('anything');
    expect(r.isError, isTrue);
    expect(r.content, contains('token budget exhausted'));
    expect(r.content, contains('spent 100 of limit 100'));
    h.host.close();
    h.dir.deleteSync(recursive: true);
  });

  test('cancelling a launched sub-agent via the subagent tool', () async {
    final ws = workspace();
    final h = harness(
      dir: ws.dir,
      scripts: [
        [
          scriptedReply('', calls: [
            ToolUseBlock(
                id: 'c1',
                name: 'launch_subagent',
                input: {'prompt': 'long work'}),
          ]),
        ],
        [scriptedReply('parent done')],
      ],
      childProvider: StallingProvider(),
    );
    await h.host.send('go');
    final id = h.plugin.launchedChildIds.single;
    final r = await h.plugin.inspect(id, action: 'cancel');
    expect(r.isError, isTrue);
    expect(r.content, contains('cancelled'));
    expect(h.plugin.childrenInFlight, 0);
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
                id: 'c1', name: 'launch_subagent', input: {'prompt': 'do work'}),
          ]),
        ],
        [scriptedReply('parent done')],
      ],
      childScripts: [
        [
          scriptedTurn('child work done',
              usage: const TokenUsage(inputTokens: 30, outputTokens: 12)),
        ],
      ],
    );
    await h.host.send('go');
    final id = h.plugin.launchedChildIds.single;
    await h.plugin.inspect(id, action: 'wait');
    expect(h.plugin.parent.details.tokensSpent, 42);
    expect(h.plugin.budget.spent, 42);
    h.dir.deleteSync(recursive: true);
  });

  test('wait streams the child\'s live tool activity as progress', () async {
    final ws = workspace();
    final h = harness(
      dir: ws.dir,
      scripts: [
        [
          scriptedReply('', calls: [
            ToolUseBlock(
                id: 'c1', name: 'launch_subagent', input: {'prompt': 'do work'}),
          ]),
        ],
        [scriptedReply('parent done')],
      ],
      childScripts: [
        [
          scriptedReply('', calls: [
            ToolUseBlock(id: 'list', name: 'ls', input: {'path': '.'}),
          ]),
          scriptedReply('child done'),
        ],
      ],
    );
    await h.host.send('go');
    final id = h.plugin.launchedChildIds.single;
    final progressLines = <String>[];
    final r = await h.plugin.inspect(id,
        action: 'wait', progress: progressLines.add);
    expect(r.isError, isFalse);
    expect(r.content, contains('child done'));
    expect(progressLines, isNotEmpty);
    // The child's tool activity is forwarded live; a finished tool call is
    // always observable (a 'running' start may be missed if the child's
    // scripted tool completes before wait attaches).
    expect(progressLines, contains(contains('ls: done')));
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
            ToolUseBlock(id: 'c1', name: 'launch_subagent', input: {
              'prompt': 'write escape.txt with the write tool',
            }),
          ]),
        ],
        [scriptedReply('parent done')],
      ],
      childScripts: [
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
      ],
    );
    var asked = false;
    h.tools.sandbox.approver = (request, reason) async {
      asked = true;
      return Approval.no;
    };
    await h.host.send('try to escape');
    final id = h.plugin.launchedChildIds.single;
    await h.plugin.inspect(id, action: 'wait');
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
                name: 'launch_subagent',
                input: {'prompt': 'write a file inside the workspace'}),
          ]),
        ],
        [scriptedReply('parent done')],
      ],
      childScripts: [
        [
          scriptedReply('', calls: [
            ToolUseBlock(
                id: 'w1',
                name: 'write',
                input: {'filePath': 'inside.txt', 'content': 'from the child'}),
          ]),
        ],
        [scriptedReply('wrote it')],
      ],
    );
    await h.host.send('write via child');
    final id = h.plugin.launchedChildIds.single;
    await h.plugin.inspect(id, action: 'wait');
    expect(
        File('${ws.dir.path}/inside.txt').readAsStringSync(), 'from the child');
    h.host.close();
    h.dir.deleteSync(recursive: true);
  });

  test('the child\'s log is separate, and resumable on its own', () async {
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
                name: 'launch_subagent',
                input: {'prompt': 'remember the word basilisk'}),
          ]),
        ],
        [scriptedReply('parent done')],
      ],
      childScripts: [
        [scriptedReply('the word is basilisk')],
      ],
    );
    await h.host.send('go');
    final id = h.plugin.launchedChildIds.single;
    await h.plugin.inspect(id, action: 'wait');
    h.host.close();
    final store = SessionStore.open(storePath);
    final ids = store.list().map((s) => s.id).toList();
    final childId = ids.where((i) => i.endsWith('-child1')).single;
    expect(ids, contains(childId));
    store.close();
    final resumed = Host.resume(
      HostConfig(
        providerFactory: (model) => ScriptedProvider(const []),
        workingDirectory: ws.dir.path,
        plugins: [
          PersistencePlugin(openStore: () => SessionStore.open(storePath))
        ],
      ),
      childId,
    );
    expect(resumed.session.loop.log.whereType<InputRecordedEntry>().single.text,
        'remember the word basilisk');
    final resumedReply = resumed.session.loop.log
        .whereType<MessageAppendedEntry>()
        .map((e) => e.message)
        .where((m) => m.role == Role.assistant)
        .map((m) =>
            [for (final b in m.content.whereType<TextBlock>()) b.text].join())
        .last;
    expect(resumedReply, 'the word is basilisk');
    resumed.close();
    h.host.close();
    h.dir.deleteSync(recursive: true);
  });

  test('the parent\'s log holds the launch, and not the child\'s messages',
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
                name: 'launch_subagent',
                input: {'prompt': 'inner prompt one'}),
          ]),
        ],
        [scriptedReply('parent wrap-up')],
      ],
      childScripts: [
        [scriptedReply('child final answer')],
      ],
    );
    await h.host.send('go');
    final id = h.plugin.launchedChildIds.single;
    await h.plugin.inspect(id, action: 'wait');
    h.host.close();
    final store = SessionStore.open(storePath);
    final parentEntries = store.readEntries(h.plugin.parent.id);
    final childIds = store
        .list()
        .map((s) => s.id)
        .where((i) => i != h.plugin.parent.id)
        .toList();
    store.close();
    final calls = parentEntries
        .whereType<MessageAppendedEntry>()
        .expand((e) => e.message.content)
        .whereType<ToolUseBlock>()
        .where((b) => b.name == 'launch_subagent')
        .toList();
    expect(calls, hasLength(1));
    expect(calls.single.input['prompt'], 'inner prompt one');
    final launchResults = parentEntries
        .whereType<MessageAppendedEntry>()
        .expand((e) => e.message.content)
        .whereType<ToolResultBlock>()
        .map((b) => b.content)
        .join('\n');
    expect(launchResults, contains('launched sub-agent'));
    // And nothing of the child's transcript rides in the parent's log:
    // exactly one user input — the parent's own.
    final parentTexts =
        parentEntries.whereType<InputRecordedEntry>().map((e) => e.text);
    expect(parentTexts, ['go']);
    expect(childIds, hasLength(1));
    h.dir.deleteSync(recursive: true);
  });

  test('a child cannot launch grandchildren: the launch tool has no '
      'executor in the child', () async {
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
                name: 'launch_subagent',
                input: {'prompt': 'you may launch no further'}),
          ]),
        ],
        [scriptedReply('parent done')],
      ],
      childScripts: [
        // The child (depth 1) asks to launch; the default factory gives
        // it no sub-agents plugin, so the call has no executor.
        [
          scriptedReply('', calls: [
            ToolUseBlock(
                id: 'c2',
                name: 'launch_subagent',
                input: {'prompt': 'too deep'}),
          ]),
        ],
        [scriptedReply('child finished anyway')],
      ],
    );
    await h.host.send('go');
    final id = h.plugin.launchedChildIds.single;
    await h.plugin.inspect(id, action: 'wait');
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
    expect(childResults, contains('no executor for launch_subagent'));
    expect(ids.where((i) => i.endsWith('-child2')), isEmpty,
        reason: 'a grandchild was never built');
    expect(childId, startsWith('${h.plugin.parent.id}-'));
    h.host.close();
    h.dir.deleteSync(recursive: true);
  });

  test('resuming a session resets the stale in-flight counter', () async {
    final ws = workspace();
    final storePath = '${ws.dir.path}/store.db';
    final h = harness(
      dir: ws.dir,
      storePath: storePath,
      scripts: [
        [scriptedReply('hi')],
      ],
    );
    await h.host.send('hello'); // persist the parent session
    // Simulate the persisted state a previous run left when it quit while
    // a child was in flight: the counter is non-zero but no child is live.
    h.plugin.parent.details.childrenInFlight = 2;
    h.host.saveDetails();
    h.host.close();
    final tools = ToolsPlugin(
      workspaceRoot: ws.root,
      tinaDir: Directory('${ws.root}/.tina'),
      mode: PermissionMode.allowEdits,
      osSandbox: false,
    );
    final resumed = Host.resume(
      HostConfig(
        providerFactory: (model) => ScriptedProvider(const []),
        workingDirectory: ws.root,
        plugins: [
          tools,
          PersistencePlugin(openStore: () => SessionStore.open(storePath)),
          SubagentsPlugin(
            sessionFactory: standardChildFactory(
              parentTools: tools,
              providerFactory: (model) => ScriptedProvider(const []),
            ),
          ),
        ],
      ),
      h.plugin.parent.id,
    );
    expect(resumed.session.details.childrenInFlight, 0,
        reason: 'a resumed session has no live children; the stale counter '
            'must not lock out new launches');
    resumed.close();
    h.dir.deleteSync(recursive: true);
  });

  test('closing the parent cancels running sub-agents and releases the slots',
      () async {
    final ws = workspace();
    final h = harness(
      dir: ws.dir,
      scripts: [
        [
          scriptedReply('', calls: [
            ToolUseBlock(
                id: 'c1',
                name: 'launch_subagent',
                input: {'prompt': 'long work'}),
          ]),
        ],
        [scriptedReply('parent done')],
      ],
      childProvider: StallingProvider(),
    );
    await h.host.send('go');
    final id = h.plugin.launchedChildIds.single;
    expect(h.plugin.childrenInFlight, 1);
    // The host calls SubagentsPlugin.closeSession on close; call it
    // directly here (the harness attaches the plugin to the loop, not the
    // host's plugin list), which cancels the running child.
    h.plugin.closeSession();
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (h.plugin.childrenInFlight != 0) {
      if (DateTime.now().isAfter(deadline)) {
        fail('child did not settle after the parent closed');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final r = await h.plugin.inspect(id);
    expect(r.isError, isTrue);
    expect(r.content, contains('cancelled'));
    h.host.close();
    h.dir.deleteSync(recursive: true);
  });

  test(
      'a resumed session can retrieve a completed sub-agent that was never '
      'waited on', () async {
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
                name: 'launch_subagent',
                input: {'prompt': 'count things'}),
          ]),
        ],
        [scriptedReply('parent done')],
      ],
      childScripts: [
        [scriptedReply('the count is forty-two')],
      ],
    );
    await h.host.send('go');
    final id = h.plugin.launchedChildIds.single;
    // Let the child finish so its answer is persisted (the parent never
    // waited on it), then quit.
    await h.plugin.inspect(id, action: 'wait');
    h.host.saveDetails();
    h.host.close();

    // Resume the parent with a plugin that reads the store history.
    final tools = ToolsPlugin(
      workspaceRoot: ws.root,
      tinaDir: Directory('${ws.root}/.tina'),
      mode: PermissionMode.allowEdits,
      osSandbox: false,
    );
    final resumed = Host.resume(
      HostConfig(
        providerFactory: (model) => ScriptedProvider(const []),
        workingDirectory: ws.root,
        plugins: [
          tools,
          PersistencePlugin(openStore: () => SessionStore.open(storePath)),
          SubagentsPlugin(
            sessionFactory: standardChildFactory(
              parentTools: tools,
              providerFactory: (model) => ScriptedProvider(const []),
            ),
            history: _TestHistory(() => SessionStore.open(storePath)),
          ),
        ],
      ),
      h.plugin.parent.id,
    );
    final resumedPlugin = resumed.config.plugins.whereType<SubagentsPlugin>().single;
    expect(resumedPlugin.launchedChildIds, contains(id));
    final r = await resumedPlugin.inspect(id, action: 'status');
    expect(r.isError, isFalse);
    expect(r.content, contains('the count is forty-two'));
    resumed.close();
    h.dir.deleteSync(recursive: true);
  });
}
