import 'dart:async';
import 'dart:io';

import 'package:attractor/attractor.dart';
import 'package:path/path.dart' as p;
import 'package:tina_engine/tina_engine.dart';
import 'package:tina_app/tina_app.dart';


import 'package:tina/session_controller.dart';
import 'package:tina/completion/command_completion_provider.dart';

import 'helpers/memory_session_store.dart';
import 'package:test/test.dart';

import 'helpers/fake_host_interface.dart';
import 'helpers/fake_provider.dart';

/// A scriptable [ReadLine] for driving [SessionController.run] without a
/// terminal. [enqueue] returns a line to the next `readLine` call (or resolves
/// a readLine already waiting); [close] resolves the next call with `null` so
/// the loop exits on EOF, exactly as a closed stdin would.
class FakeReadLine {
  final _queue = <String?>[];
  Completer<String?>? _waiter;

  void enqueue(String line) {
    if (_waiter != null && !_waiter!.isCompleted) {
      _waiter!.complete(line);
      _waiter = null;
    } else {
      _queue.add(line);
    }
  }

  void close() {
    if (_waiter != null && !_waiter!.isCompleted) {
      _waiter!.complete(null);
      _waiter = null;
    } else {
      _queue.add(null);
    }
  }

  Future<String?> call(String prompt) async {
    if (_queue.isNotEmpty) return _queue.removeAt(0);
    _waiter = Completer<String?>();
    return _waiter!.future;
  }
}

/// Build a single-session [SessionController] around [provider] for testing.
/// The controller is UI-agnostic; it's exercised here entirely through its
/// [HostInterface] and [ReadLine] seams — a [FakeHostInterface] (which is also
/// the agent sink, so agent output lands in the same recorded stream) and a
/// [FakeReadLine]. No terminal types.
SessionController _buildController({
  required FakeReadLine readLine,
  required LlmProvider provider,
  SessionStore? store,
  String? sessionId,
  String? conversationId,
  Directory? workflowsDir,
  String? defaultWorkflow,
  List<Tool>? tools,
  InputRoutes? inputRoutes,
  PluginScope? pluginScope,
}) {
  // Tests that pass real tools allow them statically — the asker seam
  // (host.askPermission) stays wired but is never consulted for them.
  final policy = PermissionPolicy(defaults: {
    for (final t in tools ?? const <Tool>[]) t.schema.name:
        PermissionDecision.allow,
  });
  final toolRegistry = ToolRegistry(tools ?? const []);
  final host = FakeHostInterface();
  final agent = Agent(
    provider: provider,
    tools: toolRegistry,
    sink: host,
    policy: policy,
    asker: host.askPermission,
    system: 'sys',
  );
  // When a real store + ids are supplied, attach a recorder to the existing
  // on-disk conversation so appends flow through the same write path the live
  // REPL uses (the file is created up front by the caller).
  final SessionRecorder? recorder;
  if (store != null && sessionId != null && conversationId != null) {
    final rec = SessionRecorder(store, sessionId, conversationId,
        providerId: 'anthropic');
    rec.attach(sessionId, conversationId);
    recorder = rec;
  } else {
    recorder = null;
  }
  final session = Conversation(
    // The live conversation id follows the persisted one when the harness
    // attaches to an on-disk conversation (goal/plan dispatch keys by
    // ctx.active.id and must match the manifest's conversation id); tests
    // without a store keep the historical 's1'.
    id: conversationId ?? 's1',
    label: provider.model,
    agent: agent,
    provider: provider,
    host: host,
    policy: policy,
    recorder: recorder,
  );
  final sm = SessionManager(
    initialConversation: session,
    initialProviderId: 'anthropic',
    initialApiKey: '',
    providerFactory: (kind, key, model, baseUrl) => provider,
    hostFactory: ({
      required String conversationId,
      required bool isActive,
    }) =>
        FakeHostInterface()..setActive(isActive),
    agentBuilder: ({
      required String conversationId,
      required LlmProvider provider,
      required HostInterface host,
      required PermissionPolicy policy,
    }) =>
        AgentDriverAdapter(
      Agent(
        provider: provider,
        tools: toolRegistry,
        sink: host,
        policy: policy,
        asker: host.askPermission,
        system: 'sys',
      ),
    ),
  );
  final controller = SessionController(
    inputRoutes: inputRoutes,
    pluginScope: pluginScope,
    sessionManager: sm,
    readLine: readLine.call,
    sessionStore: store,
    onActiveFocusChanged: () {},
  );
  controller.workflowsDir = workflowsDir;
  controller.defaultWorkflow = defaultWorkflow;
  return controller;
}

/// The active conversation's host, cast back to the fake for assertions.
FakeHostInterface hostOf(SessionController c) =>
    c.active.host as FakeHostInterface;

/// Poll [pred] at a short interval until it holds, or fail. The controller's
/// turns run fire-and-forget, so tests pump until the side-effect they care
/// about (an echoed line, a queued notice, a cancelled exchange) has landed.
Future<void> _pumpUntil(bool Function() pred,
    {int iterations = 300, String reason = 'condition'}) async {
  for (var i = 0; i < iterations; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (pred()) return;
  }
  fail('pumpUntil timed out waiting: $reason');
}

void main() {
  test('plugin command help, completion and CmdRun use the live input path', () async {
    final scope = PluginScope('plugin');
    addTearDown(scope.dispose);
    final registration = scope.registerContribution(pluginId: 'test', id: 'plugin.ask',
      contribution: Command(names: ['/ask', '/a'], summary: 'ask a question',
        handler: (call) async => CmdRun(call.arguments)));
    final router = _StalledInputRouter();
    scope.registerContribution(pluginId: 'test', id: 'router', contribution: router);
    final input = FakeReadLine();
    final provider = FakeProvider.done();
    final controller = _buildController(readLine: input, provider: provider,
      inputRoutes: InputRoutes(scope), pluginScope: scope);
    final completion = CommandCompletionProvider(names: () => controller.commands.allNames);
    expect(await completion.complete('a'), containsAll(['/ask', '/a']));
    input.enqueue('/help');
    final run = controller.run();
    await _pumpUntil(() => hostOf(controller).messages.join().contains('ask a question'));
    expect(router.seen, isEmpty);
    input.enqueue('/a hello');
    await _pumpUntil(() => provider.calls.isNotEmpty);
    await controller.turns.whenIdle(controller.active.id);
    expect(router.seen, ['hello']);
    await registration.dispose();
    expect(await completion.complete('ask'), isEmpty);
    expect(controller.commands.lookup('/ask'), isNull);
    expect(controller.commands.renderHelp(), isNot(contains('ask a question')));
    input.close();
    await run;
    expect(scope.isAdmitting, isTrue, reason: 'the frontend borrows app plugins');
  });
  test('commands bypass routers and cancelNow releases a stalled input plugin', () async {
    final scope = PluginScope('input');
    addTearDown(scope.dispose);
    final router = _StalledInputRouter();
    scope.registerContribution(pluginId: 'test', id: 'router', contribution: router);
    final input = FakeReadLine();
    final provider = FakeProvider.done();
    final controller = _buildController(readLine: input, provider: provider,
      inputRoutes: InputRoutes(scope));
    var settingsOpened = false;
    controller.openSettings = () async { settingsOpened = true; };
    input.enqueue('/settings');
    final run = controller.run();
    await _pumpUntil(() => settingsOpened);
    expect(router.seen, isEmpty);
    input.enqueue('first');
    await router.started.future;
    input.enqueue('discard');
    await _pumpUntil(() => controller.active.pendingInputs == 2 && router.seen.contains('discard'));
    expect(controller.cancelNow(), isTrue);
    await controller.turns.whenIdle(controller.active.id).timeout(const Duration(seconds: 1));
    expect(controller.active.messageQueue.isEmpty, isTrue);
    expect(controller.active.isRunning, isFalse);
    input.enqueue('replacement');
    await _pumpUntil(() => provider.calls.isNotEmpty);
    await controller.turns.whenIdle(controller.active.id);
    input.close();
    await run;
    expect(router.seen, ['first', 'discard', 'replacement']);
    expect(provider.calls, hasLength(1));
  });
  test('/explore runs under the restricted turn catalog and restores normal tools', () async {
    final read = _ExplorationForbiddenTool();
    final provider = FakeProvider(const [
      [MessageComplete(content: [ToolUseBlock(id: 'read-1', name: 'read', input: {'path': 'a.dart'})], stopReason: 'tool_use')],
      [MessageComplete(content: [TextBlock('done')], stopReason: 'end_turn')],
    ]);
    final input = FakeReadLine();
    final controller = _buildController(readLine: input, provider: provider,
      tools: [read, ExploreProjectTool(open: () => null)]);
    input.enqueue('/explore widget');
    final run = controller.run();
    await _pumpUntil(() => provider.calls.length == 2);
    await controller.turns.whenIdle(controller.active.id);
    input.close();
    await run;
    expect(read.calls, 0);
    expect(provider.calls.first.tools.map((t) => t.name), ['ask_user', 'explore_project']);
    expect(controller.active.driver.tools['read'], same(read));
  });

  _inputCaptureTests();
  group('SessionController', () {
    test('echoes user input to chat before agent turn', () async {
      final rl = FakeReadLine();
      final controller =
          _buildController(readLine: rl, provider: FakeProvider.done());

      rl.enqueue('hi');
      final runFuture = controller.run();
      await _pumpUntil(
          () => hostOf(controller).messages.any((m) => m.contains('hi')));
      rl.close();
      await runFuture;

      expect(hostOf(controller).messages.any((m) => m.contains('hi')), isTrue,
          reason: 'user input should be echoed to chat');
    });

    test('/settings invokes the wired openSettings callback', () async {
      final rl = FakeReadLine();
      final controller =
          _buildController(readLine: rl, provider: FakeProvider.done());
      var opened = false;
      controller.openSettings = () async {
        opened = true;
      };

      rl.enqueue('/settings');
      final runFuture = controller.run();
      await _pumpUntil(() => opened);
      rl.close();
      await runFuture;

      expect(opened, isTrue);
    });

    test('/settings without a callback (headless) prints a fallback hint',
        () async {
      final rl = FakeReadLine();
      final controller =
          _buildController(readLine: rl, provider: FakeProvider.done());
      // openSettings left null — as in the headless path.

      rl.enqueue('/settings');
      final runFuture = controller.run();
      await _pumpUntil(() => hostOf(controller)
          .messages
          .any((m) => m.contains('interactive TUI')));
      rl.close();
      await runFuture;

      expect(
          hostOf(controller).messages.any((m) => m.contains('interactive TUI')),
          isTrue);
    });

    test('auto-compact summarizes a large history before the agent turn',
        () async {
      final rl = FakeReadLine();
      // First provider call: the compact summary. Second: the turn's answer.
      final provider = FakeProvider([
        [
          const TextDelta('SUMMARY'),
          const MessageComplete(
              content: [TextBlock('SUMMARY')], stopReason: 'end_turn'),
        ],
        [
          const TextDelta('answer'),
          const MessageComplete(
              content: [TextBlock('answer')], stopReason: 'end_turn'),
        ],
      ]);
      final controller = _buildController(readLine: rl, provider: provider);
      // Low threshold + three prior exchanges → the prefix exceeds it and the
      // oldest exchange gets summarized away (preserveRecent defaults to 2).
      controller.autoCompactThreshold = 10;
      controller.active.history.addAll([
        const Message(
            role: Role.user, content: [TextBlock('old question one')]),
        const Message(
            role: Role.assistant,
            content: [TextBlock('old answer one enough')]),
        const Message(
            role: Role.user, content: [TextBlock('old question two')]),
        const Message(
            role: Role.assistant,
            content: [TextBlock('old answer two enough')]),
        const Message(
            role: Role.user, content: [TextBlock('old question three')]),
        const Message(
            role: Role.assistant,
            content: [TextBlock('old answer three enough')]),
      ]);

      rl.enqueue('hi');
      final runFuture = controller.run();
      await _pumpUntil(() => controller.active.history.any(
          (m) => m.content.any((b) => b is TextBlock && b.text == 'answer')));
      rl.enqueue('/exit');
      await runFuture.timeout(const Duration(seconds: 5));

      // The oldest exchange was summarized away; the summary and the new answer
      // are present, and a kept recent exchange survives.
      final texts = controller.active.history
          .expand((m) => m.content)
          .whereType<TextBlock>()
          .map((b) => b.text)
          .toSet();
      expect(
          texts.any((t) => t.contains('Prior conversation summary')), isTrue);
      expect(texts.any((t) => t.contains('SUMMARY')), isTrue);
      expect(texts.any((t) => t.contains('old answer one')), isFalse,
          reason: 'the oldest exchange should have been summarized away');
      expect(texts, contains('answer'));
    });

    test('empty input is not echoed', () async {
      final rl = FakeReadLine();
      final controller =
          _buildController(readLine: rl, provider: FakeProvider.done());

      rl.enqueue('');
      rl.enqueue('/exit');
      final runFuture = controller.run();
      // Let the loop read the empty line (skipped, no echo), then /exit
      // (dispatched + echoed as "/exit") — proving the empty line produced
      // no echo of its own.
      await _pumpUntil(
          () => hostOf(controller).messages.any((m) => m.contains('/exit')));
      rl.close();
      await runFuture;

      expect(hostOf(controller).messages.any((m) => m == '\n'), isFalse,
          reason: 'empty input should not be echoed');
    });

    test('/exit quits cleanly', () async {
      final rl = FakeReadLine();
      final controller =
          _buildController(readLine: rl, provider: FakeProvider.done());

      rl.enqueue('/exit');
      await controller.run().timeout(const Duration(seconds: 5));

      expect(
          hostOf(controller).messages.any((m) => m.contains('/exit')), isTrue);
    });

    test('/index invokes classification without starting a conversation turn',
        () async {
      final rl = FakeReadLine();
      final provider = FakeProvider.done();
      final controller =
          _buildController(readLine: rl, provider: provider);
      final modes = <String>[];
      controller.runClassification = (conversation, mode) async {
        expect(conversation, same(controller.active));
        modes.add(mode.mode);
      };

      rl.enqueue('/index');
      final runFuture = controller.run();
      await _pumpUntil(() => modes.isNotEmpty);
      rl.close();
      await runFuture;

      expect(modes, ['']);
      expect(provider.calls, isEmpty);
    });

    test('a command is processed after a turn has been started', () async {
      // Proves the loop returns to readLine instead of blocking on the turn.
      final rl = FakeReadLine();
      final controller =
          _buildController(readLine: rl, provider: FakeProvider.done());

      rl.enqueue('hi'); // starts a turn
      final runFuture = controller.run().timeout(const Duration(seconds: 5));
      await _pumpUntil(
          () => hostOf(controller).messages.any((m) => m.contains('hi')));
      rl.enqueue('/exit');

      await runFuture; // must complete cleanly (no timeout)

      expect(hostOf(controller).messages.any((m) => m.contains('hi')), isTrue);
    });

    test('plain text typed while a turn is running is queued', () async {
      final rl = FakeReadLine();
      final controller =
          _buildController(readLine: rl, provider: _SlowProvider());

      rl.enqueue('hi'); // starts a never-ending turn
      final runFuture = controller.run();
      await _pumpUntil(() => controller.active.isRunning);
      // "more" while the turn is still running.
      rl.enqueue('more');
      await _pumpUntil(
          () => hostOf(controller).messages.any((m) => m.contains('queued')));

      // Exit the loop; the never-completing turn is abandoned, as in the
      // original (the controller sits at readLine, not blocked on the turn).
      rl.close();
      await runFuture;

      expect(
          hostOf(controller).messages.any((m) => m.contains('queued')), isTrue,
          reason: 'input during a running turn should be queued');
    });

    test('ESC cancels in-flight response and preserves history', () async {
      final rl = FakeReadLine();
      final controller =
          _buildController(readLine: rl, provider: _SlowProvider());

      rl.enqueue('hi');
      final runFuture = controller.run();
      await _pumpUntil(() => controller.active.isRunning);
      // ESC is wired to cancelActiveTurn by the host; the controller is
      // UI-agnostic, so drive cancel directly. First Esc arms the warning;
      // second Esc actually cancels.
      expect(controller.cancelActiveTurn(), isTrue,
          reason: 'first Esc returns true (consumed)');
      final host = hostOf(controller);
      expect(host.messages.any((m) => m.contains('Press Esc again')), isTrue,
          reason: 'first Esc shows warning');
      expect(controller.cancelActiveTurn(), isTrue,
          reason: 'second Esc returns true (consumed)');
      await _pumpUntil(() => !controller.active.isRunning);
      rl.close();
      await runFuture;

      expect(host.notices.any((n) => n.contains('[cancelled]')), isTrue,
          reason: 'cancelled response should be indicated');
      expect((controller.active.history.first.content.first as TextBlock).text, 'hi');
      expect((controller.active.history.last.content.single as TextBlock).text, '[cancelled]');
    });

    test('cancelNow stops an in-flight tool and settles host activity', () async {
      final input = FakeReadLine();
      final tool = _CancelAwareTool();
      final controller = _buildController(readLine: input, tools: [tool],
        provider: FakeProvider([
          [MessageComplete(content: [ToolUseBlock(id: 'c1', name: 'cancel_wait', input: {})], stopReason: 'tool_use')],
        ]));
      input.enqueue('wait for cancellation');
      final run = controller.run();
      await tool.started.future;
      expect(controller.active.isRunning, isTrue);
      expect(controller.cancelNow(), isTrue);
      await controller.turns.whenIdle(controller.active.id).timeout(const Duration(seconds: 2));
      expect(controller.active.isRunning, isFalse);
      expect(hostOf(controller).activitySignals.last, isFalse);
      input.close();
      await run;
    });

    test('cancelNow force-cancels a running turn with no arming step',
        () async {
      // The double-Esc gesture: the first Esc (arming, or swallowed by a
      // permission modal) already served as the warning — the second must
      // stop the run outright.
      final rl = FakeReadLine();
      final controller =
          _buildController(readLine: rl, provider: _SlowProvider());

      rl.enqueue('hi');
      final runFuture = controller.run();
      await _pumpUntil(() => controller.active.isRunning);

      expect(controller.cancelNow(), isTrue,
          reason: 'something was running — the second Esc is consumed');
      final host = hostOf(controller);
      expect(host.messages.any((m) => m.contains('Press Esc again')), isFalse,
          reason: 'no arming warning on the force path');
      await _pumpUntil(() => !controller.active.isRunning);
      rl.close();
      await runFuture;

      expect(host.notices.any((n) => n.contains('[cancelled]')), isTrue,
          reason: 'the force-cancelled turn is indicated');
      expect((controller.active.history.first.content.first as TextBlock).text, 'hi');
      expect((controller.active.history.last.content.single as TextBlock).text, '[cancelled]');
    });

    test('cancelNow stops inactive conversations and all background job kinds', () async {
      final controller = _buildController(readLine: FakeReadLine(), provider: _SlowProvider());
      final original = controller.active;
      controller.turns.submit(original.id, 'background turn');
      await controller.newSession();
      expect(controller.active, isNot(same(original)));
      expect(controller.active.isRunning, isFalse);
      final job = controller.jobs.start('custom-job', original.id, (job) => job.cancelled)!;
      expect(controller.cancelNow(), isTrue);
      await Future.wait([controller.turns.whenIdle(original.id), job.done]);
      expect(original.isRunning, isFalse);
      expect(job.cancellationRequested, isTrue);
      expect(controller.jobs.hasActiveJobs, isFalse);
      await controller.shutdown();
    });

    test('cancelNow stops manual compaction and releases command dispatch', () async {
      final input = FakeReadLine();
      final controller = _buildController(readLine: input, provider: _SlowProvider());
      controller.active.history.add(const Message(role: Role.user, content: [TextBlock('history')]));
      input.enqueue('/compact');
      final run = controller.run();
      await _pumpUntil(() => hostOf(controller).sink.texts.contains('streaming'));
      expect(controller.cancelNow(), isTrue);
      await _pumpUntil(() => controller.commandCancelSignal == null);
      expect(hostOf(controller).activitySignals.last, isFalse);
      expect(controller.active.history.single.content.single, isA<TextBlock>());
      input.close();
      await run;
    });

    test('cancelNow discards pending instructions and accepts a replacement', () async {
      final input = FakeReadLine();
      final controller = _buildController(readLine: input, provider: _SlowProvider());
      input.enqueue('first');
      final run = controller.run();
      await _pumpUntil(() => controller.active.isRunning);
      input.enqueue('discard me');
      await _pumpUntil(() => controller.active.messageQueue.isNotEmpty);
      controller.cancelNow();
      await controller.turns.whenIdle(controller.active.id);
      expect(controller.active.messageQueue.isEmpty, isTrue);
      expect(hostOf(controller).activitySignals.last, isFalse);
      expect(hostOf(controller).messages.any((m) => m.startsWith('discard me\n')), isFalse);
      input.enqueue('replacement');
      await _pumpUntil(() => controller.active.isRunning);
      expect((controller.active.history.last.content.first as TextBlock).text, 'replacement');
      controller.cancelNow();
      await controller.turns.whenIdle(controller.active.id);
      input.close();
      await run;
    });

    test('#31: cancelling a turn keeps the queue and drains it into the next '
        'turn (previously "[N queued messages discarded]")', () async {
      final rl = FakeReadLine();
      final controller =
          _buildController(readLine: rl, provider: _SlowProvider());

      rl.enqueue('hi'); // starts a never-ending turn
      final runFuture = controller.run();
      await _pumpUntil(() => controller.active.isRunning);
      rl.enqueue('survivor 1');
      rl.enqueue('survivor 2');
      await _pumpUntil(() => controller.active.messageQueue.length == 2,
          reason: 'both messages queued while running');

      controller.cancelActiveTurn(); // ordinary cancellation retains the queue
      controller.cancelActiveTurn();
      // The unwind retains the cancelled exchange and drains survivor 1
      // into the next turn; pump until that turn is running.
      await _pumpUntil(
          () =>
              controller.active.isRunning &&
              hostOf(controller)
                  .messages
                  .any((m) => m.contains('survivor 1')),
          reason: 'survivor 1 becomes a turn after the cancelled one');

      expect(
          (controller.active.history.first.content.first as TextBlock).text,
          'hi', reason: 'cancellation keeps the original prompt');
      expect(
          (controller.active.history.last.content.first as TextBlock).text,
          'survivor 1', reason: 'the queued turn starts after preserved progress');
      expect(controller.active.messageQueue.length, 1,
          reason: 'survivor 2 waits for its own turn');
      rl.close();
      await runFuture;

      expect(
          hostOf(controller)
              .messages
              .any((m) => m.contains('discarded')),
          isFalse,
          reason: 'the discard notice is gone — the queue survives cancel');
      expect(controller.active.messageQueue, isNotNull);
      expect(controller.active.messageQueue.length, 0,
          reason: 'shutdown rejects the remaining backlog after cancellation settles');
    });

    test('#31: a turn that ends on its own starts the queued next turn '
        '(drain decision precedes clearing the run flag)', () async {
      // Race regression: the run flag used to clear before the dequeue, so a
      // submit landing in that window started a SECOND concurrent turn
      // alongside the drained one. With the fix the drain decision is made
      // while the flag still holds; a submit after it enqueues behind [next].
      // A gated tool parks each of the first two turns mid-flight (a tool
      // call in flight = the turn is observably running, no isRunning race);
      // the third submit needs no gate — the turn loop has shut by then.
      final gate1 = Completer<void>();
      final gate2 = Completer<void>();
      final tool = _TwoGateTool()
        ..gate1 = gate1
        ..gate2 = gate2;
      final rl = FakeReadLine();
      final controller = _buildController(
          readLine: rl,
          provider: FakeProvider([
            [
              const MessageComplete(
                content: [
                  ToolUseBlock(id: 't1', name: 'gated', input: {'n': 1}),
                ],
                stopReason: 'tool_use',
              ),
            ],
            [
              const MessageComplete(
                content: [
                  ToolUseBlock(id: 't2', name: 'gated', input: {'n': 2}),
                ],
                stopReason: 'tool_use',
              ),
            ],
            _answer('third done'),
          ]),
          tools: [tool]);

      rl.enqueue('first'); // parks turn 1 on gate1
      final runFuture = controller.run();
      await _pumpUntil(() => tool.calls == 1, reason: 'turn 1 in flight');

      // 'second' is typed while the first turn runs — it must be QUEUED and
      // drained as a sequential second turn, never run concurrently.
      rl.enqueue('second');
      await _pumpUntil(() => controller.active.messageQueue.isNotEmpty,
          reason: "the submit landed in the queue while turn 1 ran");

      gate1.complete(); // turn 1 finishes on its own (no cancel)
      await _pumpUntil(() => tool.calls == 2,
          reason: 'the drain dequeued "second" and turn 2 is in flight');

      // A submit racing the next drain window queues behind the running
      // turn instead of starting a third concurrent one.
      rl.enqueue('third');
      await _pumpUntil(() => controller.active.messageQueue.isNotEmpty,
          reason: 'the raced submit queued behind the running turn 2');
      gate2.complete();
      await _pumpUntil(
          () => hostOf(controller).sink.texts.join().contains('third done'),
          reason: 'the third message ran as a sequential third turn');
      rl.close();
      await runFuture;

      // Tool-result carriers are user-role too; count only the typed turns,
      // in order — the race would show a duplicated/interleaved exchange.
      expect(
          controller.active.history
              .where((m) =>
                  m.role == Role.user &&
                  m.content.any((b) => b is TextBlock))
              .map((m) => (m.content.firstWhere((b) => b is TextBlock)
                      as TextBlock)
                  .text),
          ['first', 'second', 'third'],
          reason: 'three user turns ran SEQUENTIALLY — the race would show a '
              'duplicated or interleaved exchange here');
    });

    test('#31 interrupt gesture: Enter on empty with queued work breaks into '
        'the run; batch ships whole and the backlog drains after', () async {
      final gate = Completer<void>();
      final tool = _GatedTool(gate);
      final rl = FakeReadLine();
      final controller = _buildController(
        readLine: rl,
        provider: FakeProvider([
          [
            const MessageComplete(
              content: [
                ToolUseBlock(id: 'c1', name: 'gated', input: {'n': 1}),
                ToolUseBlock(id: 'c2', name: 'gated', input: {'n': 2}),
              ],
              stopReason: 'tool_use',
            ),
          ],
          // The drain turn's answer (the queue survives the interrupt).
          _answer('drain turn done'),
        ]),
        tools: [tool],
      );

      rl.enqueue('go'); // starts the turn: c1 parks on the gate
      final runFuture = controller.run();
      await _pumpUntil(() => controller.active.isRunning);
      await _pumpUntil(() => tool.calls == 1, reason: 'c1 in flight');

      rl.enqueue('what I typed while waiting'); // lands in the queue
      await _pumpUntil(() => controller.active.messageQueue.isNotEmpty,
          reason: 'queued while the turn runs');

      rl.enqueue(''); // THE GESTURE: empty Enter = interrupt
      await _pumpUntil(
          () => hostOf(controller)
              .messages
              .any((m) => m.contains('interrupting — queued input next')),
          reason: 'the controller recognized the gesture and armed the '
              'interrupt');

      gate.complete(); // the in-flight call returns (kill landed in prod)
      await _pumpUntil(
          () => hostOf(controller)
              .notices
              .any((n) => n.contains('interrupted by operator')),
          reason: 'the engine attributed the in-flight call: its result '
              'ships with the operator line');
      // (The queue length is NOT asserted here: ending the turn drains it
      // into the next turn immediately — asserted below via the echo.)
      expect(controller.active.history.any((m) =>
          m.role == Role.user &&
          m.content.any((b) =>
              b is ToolResultBlock &&
              b.content
                  .startsWith('interrupted by operator'))), isTrue,
          reason: 'the in-flight result carries the operator line');
      expect(controller.active.agent.abortedKind, AbortedKind.none,
          reason: 'an interrupt is not a cancel — no abort, no rollback');

      // The backlog drains as a fresh turn and runs to its own completion.
      await _pumpUntil(
          () => hostOf(controller)
              .sink
              .texts
              .join()
              .contains('drain turn done'),
          reason: 'the queued message became the next turn and completed');
      rl.close();
      await runFuture;

      // The abortedReason the AGENT tracked for the turn that owned the
      // batch: the interrupt ends it cleanly (an interrupt is not an abort),
      // while the drain turn completed normally on its own script.
      expect(controller.active.agent.abortedKind, AbortedKind.none,
          reason: 'neither the interrupted turn nor the drain turn aborted');

      expect(tool.calls, 1,
          reason: 'c2 never executed — it stubbed (the fake provider has no '
              'further step; the tool-call count is the observable)');
      expect(
          hostOf(controller)
              .notices
              .any((n) => n.contains('[cancelled]')),
          isFalse,
          reason: 'no cancel semantics fired');
    });

    test('#31 gesture is inert without queued work (empty Enter stays a '
        'no-op when the queue is empty)', () async {
      final gate = Completer<void>();
      final tool = _GatedTool(gate);
      final rl = FakeReadLine();
      final controller = _buildController(
        readLine: rl,
        provider: FakeProvider([
          [
            const MessageComplete(
              content: [
                ToolUseBlock(id: 'c1', name: 'gated', input: {'n': 1}),
              ],
              stopReason: 'tool_use',
            ),
          ],
        ]),
        tools: [tool],
      );

      rl.enqueue('go');
      final runFuture = controller.run();
      await _pumpUntil(() => tool.calls == 1, reason: 'c1 in flight');

      rl.enqueue(''); // running, but NOTHING queued — must stay inert
      await _pumpUntil(() => hostOf(controller).messages.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
          hostOf(controller)
              .notices
              .any((n) => n.contains('interrupted by operator')),
          isFalse,
          reason: 'no queued work — the gesture does nothing');
      expect(tool.calls, 1);
      expect(controller.active.messageQueue, isEmpty);

      gate.complete();
      rl.close();
      await runFuture;
    });

    test('cancelNow returns false when nothing runs (idle input-clear path)',
        () async {
      final controller = _buildController(
          readLine: FakeReadLine(), provider: FakeProvider.done());

      expect(controller.cancelNow(), isFalse,
          reason: 'the editor only consumes the second Esc when a run stops; '
              'idle double-Esc keeps its input-clear meaning');
    });

    test('cancelNow force-cancels from the ARMED state (modal-swallowed Esc)',
        () async {
      // Owner scenario shape: first Esc is eaten elsewhere (an approval row
      // treats it as "deny") but armed the warning; the second must complete
      // the cancel WITHOUT a fresh warning.
      final rl = FakeReadLine();
      final controller =
          _buildController(readLine: rl, provider: _SlowProvider());

      rl.enqueue('hi');
      final runFuture = controller.run();
      await _pumpUntil(() => controller.active.isRunning);
      expect(controller.cancelActiveTurn(), isTrue); // arms
      final host = hostOf(controller);
      final warningsBefore = host.messages
          .where((m) => m.contains('Press Esc again'))
          .length;

      expect(controller.cancelNow(), isTrue);
      await _pumpUntil(() => !controller.active.isRunning);
      rl.close();
      await runFuture;

      expect(host.messages.where((m) => m.contains('Press Esc again')).length,
          warningsBefore,
          reason: 'the force path completes the cancel, not another warning');
      expect(host.notices.any((n) => n.contains('[cancelled]')), isTrue);
    });

    test('cancelNow during unwind is consumed silently (no re-arm)', () async {
      final rl = FakeReadLine();
      final controller =
          _buildController(readLine: rl, provider: _SlowProvider());

      rl.enqueue('hi');
      final runFuture = controller.run();
      await _pumpUntil(() => controller.active.isRunning);
      expect(controller.cancelNow(), isTrue); // completes the canceller
      // A third rapid Esc lands while the turn is still unwinding — it must
      // not arm a warning for a run that is already stopping.
      final host = hostOf(controller);
      expect(controller.cancelActiveTurn(), isTrue,
          reason: 'consumed while unwinding');
      await _pumpUntil(() => !controller.active.isRunning);
      rl.close();
      await runFuture;

      expect(
          host.messages.where((m) => m.contains('Press Esc again')), isEmpty,
          reason: 'no warning was armed for the already-stopping run');
    });

    test(
        'REGRESSION: a user message survives quitting before the response '
        'completes (restored by -c)', () async {
      // Bug report: "when I send a message and quit before a response has been
      // fully received, the message I sent isn't restored the next time I run
      // with -c."
      //
      // Root cause: `_runTurn` (session_controller.dart) writes the recorder
      // only inside its `else` branch, which runs AFTER `agent.run` returns.
      // A quit mid-stream abandons that fire-and-forget turn (it was launched
      // with `unawaited(...)`), so the persistence loop never executes. The
      // user message — added to in-memory history synchronously at the very
      // start of `agent.run` (agent.dart: `history.add(userMessage)`) — exists
      // only in RAM and is lost when the process exits. There is no per-message
      // flush and no flush-on-shutdown to rescue it. (The headless `--prompt`
      // path contrasts: bin/tina.dart appends in a `finally`, so an
      // interrupted turn still persists.)
      //
      // Ground truth is the on-disk transcript — exactly what `-c` reloads — so
      // we drive a real JsonlSessionStore in a temp dir rather than the
      // in-memory fake (see the persistence-test-gap note: only the real store
      // replays what the live path wrote).
      final tmp = await Directory.systemTemp.createTemp('tina_quit_midstream_');
      addTearDown(() => tmp.delete(recursive: true));

      final store = JsonlSessionStore(tmp);
      final sid = await store.createSession(providerId: 'anthropic');
      final cid = await store.createConversation(sid);

      final rl = FakeReadLine();
      final controller = _buildController(
        readLine: rl,
        provider: _SlowProvider(), // streams but never completes
        store: store,
        sessionId: sid,
        conversationId: cid,
      );

      rl.enqueue('are you there?');
      final runFuture = controller.run();
      // Wait until the user message has landed in in-memory history —
      // agent.run adds it as its first act, but only after _runTurn's
      // auto-compact await, so isRunning alone is not enough (it is set
      // before agent.run is even called).
      // Generous budget: under full-suite CPU load the turn start (and the
      // message add) can take far longer than the default 3s window.
      await _pumpUntil(
          () => controller.active.history.any((m) =>
              m.role == Role.user &&
              m.content.any((b) => b is TextBlock && b.text == 'are you there?')),
          iterations: 3000);

      // Quit mid-stream: close input (EOF) so the controller's loop exits. The
      // in-flight _runTurn is abandoned — its post-turn persistence loop never
      // runs — exactly as when the process is killed during streaming.
      rl.close();
      await runFuture;

      final persisted = await store.loadConversation(sid, cid);
      final persistedUserText = persisted
          .where((m) => m.role == Role.user)
          .expand((m) => m.content)
          .whereType<TextBlock>()
          .map((b) => b.text)
          .toSet();

      expect(
          persistedUserText,
          contains('are you there?'),
          reason: 'The user message should be flushed to disk as soon as it is '
              'sent, so quitting before the response completes still lets `-c` '
              'restore it. This currently FAILS: _runTurn appends only after the '
              'turn completes normally, so an interrupted turn leaves the '
              'message in memory only.');
    });

    test('a /clear command hook runs before the default clear behavior',
        () async {
      final rl = FakeReadLine();
      final controller =
          _buildController(readLine: rl, provider: FakeProvider.done());
      final host = hostOf(controller);

      // The hook records whether the default handler's "cleared" message has
      // been recorded yet when the hook fires.
      final seen = <String>[];
      controller.commandHooks['/clear'] = () {
        seen.add(host.messages.any((m) => m.contains('(history cleared)'))
            ? 'after'
            : 'before');
      };

      rl.enqueue('/clear');
      final runFuture = controller.run();
      await _pumpUntil(
          () => host.messages.any((m) => m.contains('(history cleared)')));
      rl.close();
      await runFuture;

      // The hook ran *before* the default recorded its message, and the default
      // still executed afterward — proving the hook doesn't suppress it.
      expect(seen, ['before']);
      expect(host.messages.any((m) => m.contains('(history cleared)')), isTrue);
    });

    test('the /index fleet runs on the conversation\'s live model ref',
        () async {
      final rl = FakeReadLine();
      final controller =
          _buildController(readLine: rl, provider: FakeProvider.done());
      // A `/model` swap leaves the new ref on the conversation. The fleet must
      // run on it — not the session's startup provider/model (the config
      // default, which can name a model the provider cannot serve).
      final conv = controller.active;
      conv.modelReference = 'nim/live-swap';
      String? seen;
      controller.summaryIndex = _CapturingSummaryIndex((ref) => seen = ref);

      await controller.runBackgroundIndex!(conv, null);
      while (controller.isIndexRunning) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(seen, 'nim/live-swap');
    });
  });

  group('workflow launch (manager loop)', () {
    late Directory tmp;
    late Directory workflows;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_wf_');
      workflows = Directory(p.join(tmp.path, 'workflows'));
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    Future<void> writeDot(String source) async =>
        File(p.join(workflows.path, 'default.dot')).writeAsString(source);

    /// A provider that streams 'ok' to the host (TextDelta required — a bare
    /// MessageComplete renders nothing on the sink).
    FakeProvider okProvider() => FakeProvider(const [
          [
            TextDelta('ok'),
            MessageComplete(
                content: [TextBlock('ok')], stopReason: 'end_turn'),
          ],
        ]);

    test('a normal turn runs the plain agent even when default.dot exists',
        () async {
      // The defining change of the manager-loop model: a workflow on disk no
      // longer wraps a chat turn. The plain agent runs.
      workflows.createSync(recursive: true);
      await writeDot(kDefaultWorkflowDotSource);
      final rl = FakeReadLine();
      final controller = _buildController(
        readLine: rl,
        provider: okProvider(),
        workflowsDir: workflows,
      );

      rl.enqueue('hello');
      final runFuture = controller.run();
      await _pumpUntil(
          () => hostOf(controller).sink.texts.any((t) => t.contains('ok')));
      rl.close();
      await runFuture;

      // The plain agent ran.
      expect(hostOf(controller).sink.texts.any((t) => t.contains('ok')), isTrue);
    });

    test('bare /workflow lists workflows with hints and marks the default',
        () async {
      workflows.createSync(recursive: true);
      await writeDot(kDefaultWorkflowDotSource);
      final rl = FakeReadLine();
      final controller = _buildController(
        readLine: rl,
        provider: FakeProvider.done(),
        workflowsDir: workflows,
      );

      rl.enqueue('/workflow');
      final runFuture = controller.run();
      await _pumpUntil(() => hostOf(controller)
          .messages
          .any((m) => m.contains('usage:')));
      rl.close();
      await runFuture;

      final msgs = hostOf(controller).messages.join('\n');
      // The default is marked; run/stop are gone (the agent launches workflows).
      expect(msgs, contains('default   ← default'));
      expect(msgs, contains('usage:'));
      expect(msgs, isNot(contains('/workflow run')));
      expect(msgs, isNot(contains('/workflow stop')));
      expect(msgs, contains('VERDICT: <label>'));
      expect(msgs, contains('llm_model + llm_provider'));
    });
  });

  group('injectWorkflowResult (auto agent turn on workflow completion)', () {
    // A finished run the supervisor's onComplete hook would hand the
    // controller. The harness conversation is 's1' (see _buildController).
    WorkflowRun finishedRun({
      String conversationId = 's1',
      WorkflowRunStatus status = WorkflowRunStatus.completed,
      Outcome? outcome,
    }) =>
        WorkflowRun(
          id: '1',
          workflowName: 'default',
          conversationId: conversationId,
          goal: null,
          input: 'task',
          cancel: Completer<void>(),
        )
          ..status = status
          ..outcome = outcome;

    test('a completed run wakes the idle conversation with the outcome',
        () async {
      final rl = FakeReadLine();
      final provider = FakeProvider.done();
      final controller = _buildController(readLine: rl, provider: provider);

      controller.injectWorkflowResult(
          finishedRun(outcome: const Outcome.success(text: 'all green')));

      // The agent ran a turn for the injection (no user input needed).
      await _pumpUntil(() => provider.calls.isNotEmpty);
      final userTexts = provider.calls.single.messages
          .where((m) => m.role == Role.user)
          .expand((m) => m.content)
          .whereType<TextBlock>()
          .map((b) => b.text)
          .join('\n');
      expect(userTexts, contains('finished successfully'));
      expect(userTexts, contains('all green'));
      expect(userTexts, contains('Report the outcome'));

      // The synthetic prompt is echoed into the chat and persisted like any
      // turn (agent.run adds the user message to history).
      expect(
          hostOf(controller).messages.any((m) => m.contains('finished successfully')),
          isTrue);
      await _pumpUntil(() => controller.active.history.any((m) =>
          m.role == Role.user &&
          m.content
              .any((b) => b is TextBlock && b.text.contains('finished successfully'))));
    });

    test('a failed run hands the failure reason to the agent', () async {
      final rl = FakeReadLine();
      final provider = FakeProvider.done();
      final controller = _buildController(readLine: rl, provider: provider);

      controller.injectWorkflowResult(finishedRun(
          status: WorkflowRunStatus.failed,
          outcome: Outcome.fail('goal gate "review" unsatisfied')));

      await _pumpUntil(() => provider.calls.isNotEmpty);
      final userTexts = provider.calls.single.messages
          .where((m) => m.role == Role.user)
          .expand((m) => m.content)
          .whereType<TextBlock>()
          .map((b) => b.text)
          .join('\n');
      expect(userTexts, contains('failed'));
      expect(userTexts, contains('goal gate "review" unsatisfied'));
      expect(userTexts, contains('Report the failure'));
    });

    test('a completion while a turn is running is queued, not injected',
        () async {
      final rl = FakeReadLine();
      final controller = _buildController(readLine: rl, provider: _SlowProvider());

      rl.enqueue('hi'); // starts a never-ending turn
      final runFuture = controller.run();
      await _pumpUntil(() => controller.active.isRunning);

      controller.injectWorkflowResult(
          finishedRun(outcome: const Outcome.success(text: 'all green')));

      await _pumpUntil(
          () => hostOf(controller).messages.any((m) => m.contains('queued')));
      expect(controller.active.messageQueue.isNotEmpty, isTrue);
      // No second turn was started: the prompt was only queued, so it was never
      // echoed as a user message (an injected turn would echo it).
      expect(
          hostOf(controller)
              .messages
              .any((m) => m.contains('finished successfully')),
          isFalse);

      rl.close();
      await runFuture;
    });

    test('a cancelled run is a no-op (already communicated via stop)',
        () async {
      final rl = FakeReadLine();
      final provider = FakeProvider.done();
      final controller = _buildController(readLine: rl, provider: provider);

      controller.injectWorkflowResult(finishedRun(status: WorkflowRunStatus.cancelled));

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(provider.calls, isEmpty);
      expect(hostOf(controller).messages.any((m) => m.contains('finished')),
          isFalse);
    });

    test('a run for a closed conversation is a no-op', () async {
      final rl = FakeReadLine();
      final provider = FakeProvider.done();
      final controller = _buildController(readLine: rl, provider: provider);

      controller.injectWorkflowResult(finishedRun(
          conversationId: 'ghost',
          outcome: const Outcome.success(text: 'all green')));

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(provider.calls, isEmpty);
    });
  });

  test(
      'a turn aborted by a provider error persists its reason (visible on '
      'restore)', () async {
    final store = MemorySessionStore();
    final sid = await store.createSession(providerId: 'anthropic');
    final cid = await store.createConversation(sid);
    final provider = FakeProvider([
      [const StreamError('402 payment required — no funds')],
    ]);

    final rl = FakeReadLine();
    final controller = _buildController(
      readLine: rl,
      provider: provider,
      store: store,
      sessionId: sid,
      conversationId: cid,
    );

    rl.enqueue('do the thing');
    final runFuture = controller.run();
    await _pumpUntil(() => !controller.active.isRunning);
    rl.close();
    await runFuture;

    // The live notice was display-only; the persisted transcript carries the
    // reason as a synthetic assistant message — what a quit + restore replays.
    final persisted = await store.loadConversation(sid, cid);
    final lastText = persisted.last.content
        .whereType<TextBlock>()
        .map((b) => b.text)
        .join();
    expect(lastText,
        contains('[turn aborted: 402 payment required — no funds]'));
  });

  group('goal/plan persistence across /resume', () {
    // The controller builds a TrackerPersistence binder when the scope
    // provides BOTH tracker stores and a session store is wired: mutations
    // in the stores land in the manifest, and a resume re-hydrates the stores
    // from it (manifest authoritative — absent blobs clear).
    late PluginScope scope;
    late GoalStore goals;
    late PlanStore plans;

    setUp(() {
      scope = PluginScope('plugin');
      goals = GoalStore();
      plans = PlanStore();
      scope.provide(goalStoreServiceKey, goals);
      scope.provide(planStoreServiceKey, plans);
    });

    tearDown(() async {
      await scope.dispose();
      goals.dispose();
      plans.dispose();
    });

    SessionController trackedController(MemorySessionStore store, String sid,
            String cid) =>
        _buildController(
          readLine: FakeReadLine(),
          provider: FakeProvider.done(),
          store: store,
          sessionId: sid,
          conversationId: cid,
          pluginScope: scope,
        );

    test('a set goal/plan lands in the manifest; clearing one keeps the other',
        () async {
      final store = MemorySessionStore();
      final sid = await store.createSession(providerId: 'anthropic');
      final cid = await store.createConversation(sid);
      final controller = trackedController(store, sid, cid);

      goals.set(cid, 'ship the release');
      plans.update(cid, [
        PlanItem('write tests', state: PlanState.inProgress),
        PlanItem('commit'),
      ]);
      // The persist hook chains an async write; pump until both blobs land.
      await _pumpUntil(
          () =>
              store.metaFor(sid, cid)?.goal != null &&
              store.metaFor(sid, cid)?.plan != null,
          reason: 'trackers persisted to the manifest');
      var meta = store.metaFor(sid, cid)!;
      expect(meta.goal!['text'], 'ship the release');
      expect((meta.plan!['items'] as List), hasLength(2));
      expect(meta.plan!['approval'], 'none');

      goals.clear(cid); // null clears goal only, the plan survives
      await _pumpUntil(() => store.metaFor(sid, cid)?.goal == null,
          reason: 'cleared goal persisted');
      meta = store.metaFor(sid, cid)!;
      expect(meta.goal, isNull);
      expect(meta.plan, isNotNull);

      await controller.shutdown(); // flushes + uninstalls the binder
      expect(store.metaFor(sid, cid)!.plan, isNotNull);
    });

    test('resumeIntoActive restores trackers from the manifest', () async {
      final store = MemorySessionStore();
      final sid = await store.createSession(providerId: 'anthropic');
      final cid = await store.createConversation(sid);
      await store.updateConversationTrackers(
        sid,
        cid,
        goal: {'text': 'manifest goal'},
        plan: {
          'items': [
            {'text': 'persisted step', 'state': 'done'}
          ],
          'approval': 'approved',
        },
      );
      // Stale in-memory trackers from an earlier session in this process —
      // set BEFORE the controller exists, so no persist hook can race the
      // resume by writing them into the manifest.
      goals.set(cid, 'stale goal');
      final controller = trackedController(store, sid, cid);

      expect(await controller.resumeIntoActive(sid), isTrue);
      expect(goals.read(cid).text, 'manifest goal',
          reason: 'the manifest wins over stale in-memory state');
      expect(goals.read(cid).isEmpty, isFalse);
      expect(plans.read(cid).items.single.text, 'persisted step');
      expect(plans.read(cid).items.single.state, PlanState.done);
      expect(plans.read(cid).approval, PlanApproval.approved);
      await controller.shutdown();
    });

    test('resume clears trackers the manifest does not carry', () async {
      final store = MemorySessionStore();
      final sid = await store.createSession(providerId: 'anthropic');
      final cid = await store.createConversation(sid);
      goals.set(cid, 'stale goal'); // pre-construction → no hook, no write
      plans.update(cid, [PlanItem('stale step')]);
      final controller = trackedController(store, sid, cid);

      expect(await controller.resumeIntoActive(sid), isTrue);
      expect(goals.read(cid).isEmpty, isTrue,
          reason: 'absent goal blob clears authoritative over memory');
      expect(plans.read(cid).isEmpty, isTrue);
      await controller.shutdown();
    });

    test('hydrateTrackers restores a startup manifest (and clears stale)',
        () async {
      final store = MemorySessionStore();
      final sid = await store.createSession(providerId: 'anthropic');
      final cid = await store.createConversation(sid);
      goals.set(cid, 'stale goal'); // pre-construction → no hook, no write
      final controller = trackedController(store, sid, cid);

      controller.hydrateTrackers([
        ConversationMeta(
          id: cid,
          plan: {
            'items': [
              {'text': 'startup step', 'state': 'pending'}
            ],
          },
          // no goal blob → the stale goal must be cleared
        ),
      ]);
      expect(goals.read(cid).isEmpty, isTrue);
      expect(plans.read(cid).items.single.text, 'startup step');
      // Hydration wrote nothing back to the manifest.
      expect(store.metaFor(sid, cid)!.plan, isNull);
      await controller.shutdown();
    });

    test('mutations persist after construction; shutdown drains the write',
        () async {
      final store = MemorySessionStore();
      final sid = await store.createSession(providerId: 'anthropic');
      final cid = await store.createConversation(sid);
      final controller = trackedController(store, sid, cid);

      goals.set(cid, 'written on shutdown');
      await controller.shutdown(); // awaits the chained tracker write
      expect(store.metaFor(sid, cid)!.goal!['text'], 'written on shutdown');
    });
  });

  group('resumeIntoActive persists the pointer (quit/resume incident '
      '2026-09-23)', () {
    // `switchTo` is in-memory only; quitting after a mid-session `/resume`
    // used to reopen the PRE-resume conversation because the manifest anchor
    // was never moved. The deliberate switch must persist.
    test('/resume persists the anchor at the resumed conversation', () async {
      final store = MemorySessionStore();
      final sid = await store.createSession(providerId: 'anthropic');
      final first = await store.createConversation(sid);
      await store.append(
          sid, first, Message(role: Role.user, content: [TextBlock('first')]));
      final second = await store.createConversation(sid);
      await store.append(sid, second,
          Message(role: Role.user, content: [TextBlock('second')]));
      // Anchor second deliberately: only the FIRST conversation of a session
      // auto-anchors, and resume reopens the anchor — the incident needs the
      // stale in-memory controller (built on `first`) to disagree with disk.
      await store.setActiveConversation(sid, second);

      final controller = _buildController(
        readLine: FakeReadLine(),
        provider: FakeProvider.done(),
        store: store,
        sessionId: sid,
        conversationId: first,
      );
      expect(await controller.resumeIntoActive(sid), isTrue);
      expect((await store.loadSession(sid)).activeConversationId, second,
          reason: 'the deliberate /resume must repoint the on-disk anchor — '
              'switchTo alone is in-memory');
      expect(store.pointerWriteAt(sid), isNotNull,
          reason: 'the repoint went through setActiveConversation, not just '
              'the in-memory switch');
      await controller.shutdown();
    });

    test('/resume falls back to a readable sibling when the anchor '
        'transcript is gone (and repoints there)', () async {
      final store = MemorySessionStore();
      final sid = await store.createSession(providerId: 'anthropic');
      final first = await store.createConversation(sid);
      await store.append(
          sid, first, Message(role: Role.user, content: [TextBlock('first')]));
      final second = await store.createConversation(sid);
      await store.append(sid, second,
          Message(role: Role.user, content: [TextBlock('second')]));
      await store.setActiveConversation(sid, second);

      final controller = _buildController(
        readLine: FakeReadLine(),
        provider: FakeProvider.done(),
        store: store,
        sessionId: sid,
        conversationId: first,
      );
      // Simulate a vanished transcript: drop the anchor's messages. (The
      // memory store throws StateError from loadConversation for it.)
      store.dropConversation(second);

      expect(await controller.resumeIntoActive(sid), isTrue,
          reason: '/resume must degrade, not fail outright');
      final host = controller.active.host as FakeHostInterface;
      expect(host.messages.join('\n'), contains('unreadable'),
          reason: 'the fallback says why');
      expect((await store.loadSession(sid)).activeConversationId, first,
          reason: 'the healed pointer names the conversation actually '
              'resumed');
      await controller.shutdown();
    });

    test('/resume says why when nothing in the session reads', () async {
      final store = MemorySessionStore();
      final sid = await store.createSession(providerId: 'anthropic');
      final cid = await store.createConversation(sid);
      await store.append(
          sid, cid, Message(role: Role.user, content: [TextBlock('gone')]));
      store.dropConversation(cid);

      final controller = _buildController(
        readLine: FakeReadLine(),
        provider: FakeProvider.done(),
        store: store,
        sessionId: sid,
        conversationId: cid,
      );
      expect(await controller.resumeIntoActive(sid), isFalse);
      expect(
          (controller.active.host as FakeHostInterface).messages.join('\n'),
          contains('no readable'));
      await controller.shutdown();
    });
  });

  group('handleExitIntent — the in-tmux exit decision (tin-f5xt)', () {
    // The controller consults two seams: onTmuxExit (the Detach/Exit/Cancel
    // dialog) and detachTmux (the tmux spawn). Both are null outside tmux and
    // in headless, so the default behavior — immediate exit — is covered by
    // the null test below; the others pin the three dialog outcomes.
    test('null seam (outside tmux / headless) exits immediately', () async {
      final controller = _buildController(
        readLine: FakeReadLine(),
        provider: FakeProvider.done(),
      );
      expect(controller.onTmuxExit, isNull);
      expect(await controller.handleExitIntent(), isFalse,
          reason: 'stay=false → the REPL returns, exactly as before');
    });

    test('detach keeps running and runs the detach closure', () async {
      final controller = _buildController(
        readLine: FakeReadLine(),
        provider: FakeProvider.done(),
      );
      var detachCalls = 0;
      controller.detachTmux = () async => detachCalls++;
      controller.onTmuxExit =
          () async => TmuxExitChoice.detach;
      expect(await controller.handleExitIntent(), isTrue,
          reason: 'stay=true → the REPL loops, the process lives on');
      expect(detachCalls, 1,
          reason: 'choosing Detach must actually detach, not just stay');
    });

    test('cancel keeps running without touching the detach seam', () async {
      final controller = _buildController(
        readLine: FakeReadLine(),
        provider: FakeProvider.done(),
      );
      var detachCalls = 0;
      controller.detachTmux = () async => detachCalls++;
      controller.onTmuxExit = () async => TmuxExitChoice.cancel;
      expect(await controller.handleExitIntent(), isTrue);
      expect(detachCalls, 0, reason: 'cancel means "do nothing"');
    });

    test('exit returns — today\'s behavior, session saved, process stops',
        () async {
      final controller = _buildController(
        readLine: FakeReadLine(),
        provider: FakeProvider.done(),
      );
      controller.onTmuxExit = () async => TmuxExitChoice.exit;
      expect(await controller.handleExitIntent(), isFalse);
    });

    test('a throwing detach never blocks the exit decision', () async {
      // tmux calls stay best-effort: a failed spawn must surface as a warning
      // in the host, not crash the exit path.
      final controller = _buildController(
        readLine: FakeReadLine(),
        provider: FakeProvider.done(),
      );
      controller.detachTmux = () async => throw StateError('no tmux here');
      controller.onTmuxExit = () async => TmuxExitChoice.detach;
      expect(await controller.handleExitIntent(), isTrue);
      expect(
        hostOf(controller).messages.any((m) => m.contains('detach failed')),
        isTrue,
        reason: 'a throwing detach closure warns instead of propagating',
      );
    });

    test('null detach closure with a wired dialog still stays running',
        () async {
      // The dialog is only wired inside tmux, so this pairing is
      // unreachable in production; it pins the defensive path anyway.
      final controller = _buildController(
        readLine: FakeReadLine(),
        provider: FakeProvider.done(),
      );
      controller.onTmuxExit = () async => TmuxExitChoice.detach;
      expect(await controller.handleExitIntent(), isTrue);
    });

    test('/exit consults the dialog and stays when the user cancels',
        () async {
      final rl = FakeReadLine();
      final controller = _buildController(
        readLine: rl,
        provider: FakeProvider.done(),
      );
      controller.onTmuxExit = () async => TmuxExitChoice.cancel;
      var returned = false;
      final runFuture = controller.run().whenComplete(() => returned = true);
      rl.enqueue('/exit');
      await _pumpUntil(() =>
          hostOf(controller).messages.any((m) => m.contains('/exit')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(returned, isFalse,
          reason: 'cancel must keep the REPL loop alive');
      // Now let it exit for real so the test's run() future completes.
      controller.onTmuxExit = () async => TmuxExitChoice.exit;
      rl.close();
      await runFuture;
    });

    test('EOF (a closed stdin) consults the dialog too', () async {
      final rl = FakeReadLine();
      final controller = _buildController(
        readLine: rl,
        provider: FakeProvider.done(),
      );
      controller.onTmuxExit = () async => TmuxExitChoice.cancel;
      var returned = false;
      final runFuture = controller.run().whenComplete(() => returned = true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      rl.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(returned, isFalse,
          reason: 'an EOF answered with cancel keeps the loop alive');
      controller.onTmuxExit = () async => TmuxExitChoice.exit;
      rl.close();
      await runFuture;
    });
  });
}

class _StalledInputRouter implements InputRouter {
  final seen = <String>[];
  final started = Completer<void>();
  @override
  Future<InputRoute?> route(InputContext input) {
    seen.add(input.text);
    if (input.text == 'first') {
      started.complete();
      return Completer<InputRoute?>().future;
    }
    return Future.value(null);
  }
}

class _SlowProvider extends LlmProvider {
  _SlowProvider() : super('slow');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) {
    final controller = StreamController<StreamEvent>(sync: true);
    controller.add(const TextDelta('streaming'));
    // Intentionally NOT closed — stream stays open until subscription.cancel().
    return controller.stream;
  }
}

/// Inline answer step: a plain streamed text completion (no tool calls).
List<StreamEvent> _answer(String text) => [
      TextDelta(text),
      MessageComplete(content: [TextBlock(text)], stopReason: 'end_turn'),
    ];

/// A tool whose single gate parks execute until the test releases it, then
/// returns a fixed result. `calls` is the observable for "this call ran".
class _CancelAwareTool implements Tool {
  final started = Completer<void>();
  @override
  final schema = const ToolSchema(name: 'cancel_wait', description: 'waits for cancellation',
    inputSchema: {'type': 'object', 'properties': {}});
  @override
  Future<ToolResult> execute(Map<String, dynamic> input,
      {Future<void>? cancelSignal, ToolOutputCallback? onOutput}) async {
    started.complete();
    await cancelSignal;
    return const ToolResult('cancelled', isError: true);
  }
}

class _GatedTool implements Tool {
  _GatedTool(this._gate);

  final Completer<void> _gate;
  int calls = 0;

  @override
  final ToolSchema schema = const ToolSchema(
    name: 'gated',
    description: 'parks on a gate',
    inputSchema: {'type': 'object', 'properties': {}},
  );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    calls++;
    await _gate.future;
    return const ToolResult('gated-ok');
  }
}

/// A [SummaryIndex] whose fleet run is stubbed to capture the `modelRef` the
/// controller threads into it — the seam that proves the /index fleet runs on
/// the conversation's live ref. Everything else throws.
class _CapturingSummaryIndex implements SummaryIndex {
  _CapturingSummaryIndex(this.onRefresh);

  final void Function(String? modelRef) onRefresh;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<SummaryIndexResult> refresh({
    bool repartition = false,
    bool dryRun = false,
    List<String>? dirs,
    HostInterface? host,
    String? modelRef,
    Future<void>? cancelSignal,
  }) async {
    onRefresh(modelRef);
    return const SummaryIndexResult(
      status: SummaryIndexStatus(
        totalDirs: 1,
        staleDirs: [],
        deletedDirs: [],
        headSha: 'abc1234',
        firstRun: false,
        hasAllocations: false,
      ),
      regenerated: 1,
      regeneratedDirs: ['lib'],
      deletedDirs: [],
    );
  }
}

/// A gated tool with TWO independently controlled calls, for scenarios where
/// two successive turns must each park mid-flight (e.g. drain-race proofs:
/// each turn is observably running while the test submits the next line).
class _TwoGateTool implements Tool {
  Completer<void>? gate1;
  Completer<void>? gate2;
  int calls = 0;

  @override
  final ToolSchema schema = const ToolSchema(
    name: 'gated',
    description: 'parks on a per-call gate',
    inputSchema: {'type': 'object', 'properties': {}},
  );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final gate = calls == 0 ? gate1 : gate2;
    calls++;
    if (gate != null) await gate.future;
    return const ToolResult('gated-ok');
  }
}

void _inputCaptureTests() {
  group('input capture during dispatch (tin-y8kh)', () {
    test('a line typed during a slow dispatch runs after it settles',
        () async {
      // Models /compact: the first provider send (the summarization) hangs
      // until the test opens the gate, so `await dispatch` blocks exactly
      // like a real 147-message compaction — deterministically.
      final gate = Completer<void>();
      final provider = _GatedCompactProvider(gate);
      final rl = FakeReadLine();
      final controller = _buildController(readLine: rl, provider: provider);
      // agent.compact is a no-op on an empty history — seed a real exchange
      // so /compact's summarization genuinely calls the provider and hangs
      // on the gate exactly like a 147-message compaction.
      controller.active.history.addAll([
        const Message(
            role: Role.user, content: [TextBlock('earlier question')]),
        const Message(
            role: Role.assistant, content: [TextBlock('earlier answer')]),
      ]);
      final beginCounts = <int>[];
      var ends = 0;
      var typed = false;
      controller.beginInputCapture = (onSubmit, count) {
        beginCounts.add(count);
        // The user types a line + Enter ONCE while the dispatch is running;
        // later re-arms (from _catchUp) model no new typing.
        if (!typed) {
          typed = true;
          onSubmit('queued while compacting');
        }
      };
      controller.endInputCapture = () => ends++;
      rl.enqueue('/compact');
      final runFuture = controller.run();
      await _pumpUntil(() => provider.calls == 1,
          reason: 'summarization call in flight');
      await _pumpUntil(() => beginCounts.isNotEmpty,
          reason: 'capture armed for the dispatch window');
      // While the dispatch hangs, the captured line must NOT have executed:
      // it is held until the command settles (asserted by its absence below
      // and its presence after the gate opens). The seam's end callback also
      // fires on no-op disarm at the loop top, so raw end counts carry no
      // signal here — behavior is the contract.
      expect(
          controller.active.history.any(
            (m) =>
                m.role == Role.user &&
                m.content
                    .whereType<TextBlock>()
                    .any((b) => b.text.contains('queued while')),
          ),
          isFalse,
          reason: 'captured line must wait for the dispatch to settle');
      // The command settles; the captured line must run as a REAL turn.
      gate.complete();
      await _pumpUntil(
          () => controller.active.history.any(
                (m) =>
                    m.role == Role.user &&
                    m.content
                        .whereType<TextBlock>()
                        .any((b) => b.text.contains('queued while')),
              ),
          reason: 'captured line must reach the conversation as a turn');
      await _pumpUntil(
          () => controller.active.history.any(
                (m) =>
                    m.role == Role.assistant &&
                    m.content
                        .whereType<TextBlock>()
                        .any((b) => b.text == 'turn done'),
              ),
          reason: 'the flushed turn must actually complete');
      rl.close();
      await runFuture;
    });

    test('arms once per delivered line; disarms before the next readLine',
        () async {
      final gate = Completer<void>();
      final provider = _GatedCompactProvider(gate);
      final rl = FakeReadLine();
      final controller = _buildController(readLine: rl, provider: provider);
      // Seed history so /compact's summarization really blocks on the gate
      // (an empty history makes agent.compact return immediately).
      controller.active.history.addAll([
        const Message(
            role: Role.user, content: [TextBlock('earlier question')]),
        const Message(
            role: Role.assistant, content: [TextBlock('earlier answer')]),
      ]);
      var begins = 0;
      var ends = 0;
      controller.beginInputCapture = (_, __) => begins++;
      controller.endInputCapture = () => ends++;
      rl.enqueue('/compact');
      final runFuture = controller.run();
      await _pumpUntil(() => provider.calls == 1);
      // Pass 1: the loop top's unconditional end is a NO-OP (nothing armed
      // yet — the editor ignores it), then arming happens the moment
      // /compact is delivered. While dispatch hangs: one arm, one no-op end.
      expect(begins, 1, reason: 'armed the moment readLine delivered');
      expect(ends, 1,
          reason: 'only the pass-1 no-op disarm has fired');
      gate.complete();
      // The compact settles, the flush loop runs (arm/disarm around its own
      // dispatches would only happen with captured lines — none here), the
      // loop disarms before the next readLine (end #2, a REAL disarm), and
      // EOF unwinds (end #3, another no-op). Assert with slack: at least the
      // real disarm happened, and no new line means no new arm.
      rl.close();
      await runFuture;
      expect(begins, 1, reason: 'no new line was delivered, so no new arm');
      expect(ends, greaterThanOrEqualTo(2),
          reason: 'the armed window was disarmed before the next readLine');
    });
  });
}

/// First send hangs on [gate] (the in-flight /compact summarization), then
/// completes; every later send returns a finished turn. A never-completing
/// stream would leave the turn slot un-idleable and hang shutdown().
class _GatedCompactProvider extends LlmProvider {
  _GatedCompactProvider(this.gate) : super('gated');
  final Completer<void> gate;
  int calls = 0;
  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    calls++;
    if (calls == 1) {
      await gate.future;
      yield const MessageComplete(
          content: [TextBlock('SUMMARY')], stopReason: 'end_turn');
      return;
    }
    yield const MessageComplete(
        content: [TextBlock('turn done')], stopReason: 'end_turn');
  }
}

class _ExplorationForbiddenTool implements Tool {
  int calls = 0;
  @override
  ToolSchema get schema => const ToolSchema(name: 'read', description: 'read spy', inputSchema: {});
  @override
  Future<ToolResult> execute(Map<String, dynamic> input,
      {Future<void>? cancelSignal, ToolOutputCallback? onOutput}) async {
    calls++;
    return const ToolResult('should never execute');
  }
}
