import 'dart:async';
import 'dart:io';

import 'package:attractor/attractor.dart';
import 'package:path/path.dart' as p;
import 'package:tina_engine/tina_engine.dart';
import 'package:tina/conversation.dart';
import 'package:tina/pipeline/default_workflow.dart';
import 'package:tina/pipeline/workflow_supervisor.dart';
import 'package:tina/session_controller.dart';
import 'package:tina/session_manager.dart';
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
}) {
  final policy = PermissionPolicy();
  final tools = ToolRegistry(const []);
  final host = FakeHostInterface();
  final agent = Agent(
    provider: provider,
    tools: tools,
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
    id: 's1',
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
        Agent(
      provider: provider,
      tools: tools,
      sink: host,
      policy: policy,
      asker: host.askPermission,
      system: 'sys',
    ),
  );
  final controller = SessionController(
    sessionManager: sm,
    readLine: readLine.call,
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
Future<void> _pumpUntil(bool Function() pred, {int iterations = 300}) async {
  for (var i = 0; i < iterations; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (pred()) return;
  }
  throw TimeoutException('pumpUntil timed out');
}

void main() {
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

    test('/index runs a turn with the fixed prompt, not the raw command word',
        () async {
      // /index returns CmdRun(prompt): the controller must start a normal turn
      // with the fixed prompt as the user input, never "/index". The provider
      // records every send() call, so we assert on what the agent actually saw.
      final rl = FakeReadLine();
      final provider = FakeProvider.done();
      final controller =
          _buildController(readLine: rl, provider: provider);

      rl.enqueue('/index');
      final runFuture = controller.run();
      await _pumpUntil(() => provider.calls.isNotEmpty);
      rl.close();
      await runFuture;

      expect(provider.calls, hasLength(1));
      final userTexts = provider.calls.single.messages
          .where((m) => m.role == Role.user)
          .expand((m) => m.content)
          .whereType<TextBlock>()
          .map((b) => b.text)
          .toList();
      // The agent saw the fixed index prompt, never the raw "/index" word.
      expect(userTexts.any((t) => t.contains('AT MOST 2')), isTrue);
      expect(userTexts.any((t) => t.trim() == '/index'), isFalse);
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

    test('ESC cancels in-flight response and discards history', () async {
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
      await _pumpUntil(() => controller.active.history.isEmpty);
      rl.close();
      await runFuture;

      expect(host.notices.any((n) => n.contains('[cancelled]')), isTrue,
          reason: 'cancelled response should be indicated');
      expect(controller.active.history, isEmpty,
          reason: 'cancelled exchange should be discarded from history');
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
      // Wait until the turn is in flight: agent.run has added the user message
      // to in-memory history and is now awaiting the never-completing stream.
      await _pumpUntil(() => controller.active.isRunning);
      expect(
          controller.active.history.any((m) =>
              m.role == Role.user &&
              m.content.any((b) => b is TextBlock && b.text == 'are you there?')),
          isTrue,
          reason: 'sanity: the user message is in in-memory history once the '
              'turn is running');

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
          finishedRun(outcome: const Outcome.success(notes: 'all green')));

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
          finishedRun(outcome: const Outcome.success(notes: 'all green')));

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
          outcome: const Outcome.success(notes: 'all green')));

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
