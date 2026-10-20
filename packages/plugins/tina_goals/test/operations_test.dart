import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_goals/tina_goals.dart';
import 'package:tina_host/tina_host.dart';

final class _Provider extends LlmProvider {
  _Provider() : super('controlled');
  final calls = <StreamController<StreamEvent>>[];
  final cancelled = <int>[];
  Future<void> Function(int)? cleanup;
  bool closed = false;
  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) {
    final index = calls.length;
    final call = StreamController<StreamEvent>(onCancel: () {
      cancelled.add(index);
      return cleanup?.call(index);
    });
    calls.add(call);
    return call.stream;
  }

  void answer(String text) {
    calls.last.add(
        MessageComplete(content: [TextBlock(text)], stopReason: 'end_turn'));
    unawaited(calls.last.close());
  }

  @override
  void close() {
    closed = true;
    for (final call in calls) unawaited(call.close());
  }
}

Future<void> _until(bool Function() ready) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!ready()) {
    if (DateTime.now().isAfter(end)) fail('condition not reached');
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _Provider provider;
  late GoalsPlugin goals;
  late Host host;
  late SessionConnection client;
  setUp(() {
    provider = _Provider();
    goals = GoalsPlugin();
    host = Host.start(HostConfig(
        workingDirectory: '.',
        providerFactory: (_) => provider,
        plugins: [goals],
        operationsFor: (_) => goalsOperations));
    client = host.connect();
  });
  tearDown(() async {
    client.close();
    await host.shutdown();
  });

  SessionRequest run(String key) => client.submitOperation('tina/goals', 'run',
      arguments: {'text': 'finish'}, id: client.requestWindow.id(key));

  test(
      'goal stays busy while judging and detached execution continues to success',
      () async {
    final observer = host.connect(role: SessionRole.observer);
    addTearDown(observer.close);
    final request = run('goal');
    await _until(() => provider.calls.length == 1);
    provider.answer('first reply');
    await _until(() => provider.calls.length == 2 && !observer.status.running);
    final snapshot = observer.attach().initial;
    expect(snapshot.status.busy, isTrue);
    expect(snapshot.status.acceptsInput, isFalse);
    expect(snapshot.activeWork.single.kind, 'operation');
    expect(snapshot.activeWork.single.id, request.snapshot.workId);
    expect(observer.output(request.snapshot.id).entries.single.text,
        'first reply');
    client.close();
    provider.answer('VERDICT: no — one more step');
    await _until(() => provider.calls.length == 3);
    provider.answer('second reply');
    await _until(() => provider.calls.length == 4);
    provider.answer('VERDICT: yes — finished');
    expect((await request.completed).state, SessionRequestState.completed);
    expect(goals.goal!.verdict, GoalVerdict.achieved);
    expect(observer.status.busy, isFalse);
    expect(observer.output(request.snapshot.id).entries.map((e) => e.text),
        ['first reply', 'second reply']);
  });

  for (final phase in ['turn', 'judge']) {
    for (final shutdown in [false, true]) {
      test(
          '${shutdown ? 'shutdown' : 'cancel'} during $phase stops provider and prevents continuation',
          () async {
        final request = run('cancel-$phase');
        await _until(() => provider.calls.length == 1);
        if (phase == 'judge') {
          provider.answer('work');
          await _until(
              () => provider.calls.length == 2 && !client.status.running);
        }
        final currentCall = provider.calls.length - 1;
        if (shutdown) {
          await host.shutdown().timeout(const Duration(seconds: 3));
        } else {
          expect(client.cancel([request.snapshot.workId!]), isTrue);
        }
        expect(
            (await request.completed.timeout(const Duration(seconds: 3))).state,
            SessionRequestState.cancelled);
        expect(provider.cancelled, contains(currentCall));
        expect(provider.calls.length, currentCall + 1);
        expect(goals.goal!.verdict, GoalVerdict.none);
        expect(provider.closed, shutdown);
      });
    }
  }

  test('a cancelled judge cannot record a late verdict for identical goal text',
      () async {
    await host.shutdown();
    final judging = Completer<void>(), release = Completer<void>();
    goals = GoalsPlugin(judge: (
        {required provider,
        required goalText,
        required digest,
        required cancel}) async {
      judging.complete();
      await cancel.whenCancelled;
      await release.future;
      return (verdict: GoalVerdict.achieved, evidence: 'late');
    });
    provider = _Provider();
    host = Host.start(HostConfig(
        workingDirectory: '.',
        providerFactory: (_) => provider,
        plugins: [goals],
        operationsFor: (_) => goalsOperations));
    client.close();
    client = host.connect();
    final request = run('late');
    await _until(() => provider.calls.length == 1);
    provider.answer('work');
    await judging.future;
    client.cancel([request.snapshot.workId!]);
    expect(request.snapshot.terminal, isFalse); // cancellation still drains
    release.complete();
    expect((await request.completed).state, SessionRequestState.cancelled);
    expect(goals.goal!.verdict, GoalVerdict.none);
    expect(provider.calls, hasLength(1));
  });

  test('runtime validates goal arguments independently of CLI parsing',
      () async {
    for (final args in [
      {'text': ''},
      {'text': 'x' * 501},
      {'text': 'work', 'max_turns': 0},
      {'text': 'work', 'max_turns': '2'},
      {'text': 'work', 'unknown': true},
    ]) {
      final request = client.submitOperation('tina/goals', 'run',
          arguments: args,
          id: client.requestWindow.id('invalid-${args.hashCode}'));
      expect((await request.completed).state, SessionRequestState.failed);
    }
    expect(provider.calls, isEmpty);
  });

  test('cancellation wins over a queued judge response', () async {
    await host.shutdown();
    final entered = Completer<void>();
    final verdict = Completer<({GoalVerdict verdict, String evidence})?>();
    goals = GoalsPlugin(judge: (
        {required provider,
        required goalText,
        required digest,
        required cancel}) {
      entered.complete();
      return verdict.future;
    });
    provider = _Provider();
    host = Host.start(HostConfig(
        workingDirectory: '.',
        providerFactory: (_) => provider,
        plugins: [goals],
        operationsFor: (_) => goalsOperations));
    client.close();
    client = host.connect();
    final request = run('queued-verdict');
    await _until(() => provider.calls.length == 1);
    provider.answer('work');
    await entered.future;
    verdict.complete((verdict: GoalVerdict.achieved, evidence: 'done'));
    client.cancel([request.snapshot.workId!]);
    expect((await request.completed).state, SessionRequestState.cancelled);
    expect(goals.goal!.verdict, GoalVerdict.none);
  });

  test('cancellation at turn completion does not wait for transport cleanup',
      () async {
    final cleaning = Completer<void>(), release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    provider.cleanup = (index) async {
      if (index != 1) return;
      cleaning.complete();
      await release.future;
    };
    final request = run('boundary');
    host.session.loop.subscribe((entry, event) {
      if (entry is TurnEndedEntry && event == LogEvent.appended) {
        client.cancel([request.snapshot.workId!]);
      }
    });
    await _until(() => provider.calls.length == 1);
    provider.answer('work');
    await cleaning.future.timeout(const Duration(seconds: 3));
    expect((await request.completed.timeout(const Duration(seconds: 3))).state,
        SessionRequestState.cancelled);
    expect(client.status.busy, isFalse);
    expect(provider.calls[1].hasListener, isFalse);
    expect(release.isCompleted, isFalse);
    expect(goals.goal!.verdict, GoalVerdict.none);
    // Provider cleanup may finish later, but no longer owns a session turn or
    // a callback that could publish a late verdict.
    provider.answer('VERDICT: yes — late response');
    await host.shutdown().timeout(const Duration(seconds: 3));
    expect(provider.closed, isTrue);
    expect(goals.goal!.verdict, GoalVerdict.none);
    release.complete();
  });
}
