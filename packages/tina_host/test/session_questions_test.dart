import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

Future<void> flush() => Future<void>.delayed(Duration.zero);

final class _Tools extends AgentPlugin {
  @override
  String get id => 'test/questions';
  @override
  List<ToolSchema> get tools =>
      const [ToolSchema(name: 'ask', description: '', inputSchema: {})];
}

List<StreamEvent> _ask(String id) =>
    scriptedReply('', calls: [ToolUseBlock(id: id, name: 'ask', input: {})]);

void main() {
  late SessionQuestions questions;
  late QuestionClient first, second;
  setUp(() {
    questions = SessionQuestions();
    first = questions.connect();
    second = questions.connect();
  });
  tearDown(() {
    first.close();
    second.close();
    questions.close();
  });

  test('out-of-order responses match IDs; duplicates and foreign IDs fail',
      () async {
    final one = questions.ask('first?'), two = questions.ask('second?');
    final snapshot = first.pending;
    expect(() => snapshot.clear(), throwsUnsupportedError);
    expect(first.answer(snapshot.last.id, 'two'), isTrue);
    expect(second.answer(snapshot.last.id, 'duplicate'), isFalse);
    expect(second.answer(snapshot.first.id, 'one'), isTrue);
    expect((await one).text, 'one');
    expect((await two).text, 'two');
    final other = SessionQuestions();
    addTearDown(other.close);
    final otherClient = other.connect();
    addTearDown(otherClient.close);
    final third = other.ask('first?');
    expect(otherClient.pending.single.id, isNot(snapshot.first.id));
    expect(otherClient.answer(snapshot.first.id, 'foreign'), isFalse);
    other.close();
    expect((await third).disposition, QuestionDisposition.closed);
  });

  test('detach retains requests; reconnect observes and answers the same ID',
      () async {
    final result = questions.ask('keep waiting');
    final id = first.pending.single.id;
    var calls = 0;
    first.listen((_) => calls++);
    first.close();
    second.close();
    expect(first.answer(id, 'late callback'), isFalse);
    await flush();
    expect(calls, 1);
    final reconnected = questions.connect();
    addTearDown(reconnected.close);
    expect(reconnected.pending.single.id, id);
    expect(reconnected.answer(id, ''), isTrue);
    expect((await result).disposition, QuestionDisposition.answered);
  });

  test('a failed observer cannot block another client or resurrect a response',
      () async {
    var updates = 0;
    first.listen((pending) {
      if (pending.isNotEmpty) throw StateError('view failed');
    });
    second.listen((pending) {
      updates++;
      if (pending.isNotEmpty) second.answer(pending.single.id, 'answer');
    });
    expect((await questions.ask('question')).text, 'answer');
    await flush();
    expect(updates, greaterThanOrEqualTo(2));
    expect(first.pending, isEmpty);
  });

  test('expiry retires only its question and rejects a late answer', () async {
    final expiring = SessionQuestions(timeout: Duration.zero);
    final client = expiring.connect();
    addTearDown(client.close);
    addTearDown(expiring.close);
    final result = expiring.ask('expires');
    final request = client.pending.single;
    expect(request.expiresAt, isNotNull);
    expect((await result).disposition, QuestionDisposition.expired);
    expect(client.answer(request.id, 'late'), isFalse);
  });

  test('unattended asks and closed service never create pending requests',
      () async {
    final unattended = SessionQuestions(interactive: false);
    addTearDown(unattended.close);
    expect((await unattended.ask('no client')).disposition,
        QuestionDisposition.unavailable);
    final result = questions.ask('pending');
    final id = first.pending.single.id;
    questions.close();
    expect((await result).disposition, QuestionDisposition.closed);
    expect((await questions.ask('after close')).disposition,
        QuestionDisposition.closed);
    expect(first.answer(id, 'late'), isFalse);
    expect(first.pending, isEmpty);
  });

  test('operation scopes cancel their own questions and reject late re-asks',
      () async {
    final scope = questions.openScope();
    final other = questions.openScope();
    final one = scope.run(() => questions.ask('one'));
    final two = other.run(() => questions.ask('two'));
    scope.cancel();
    expect((await one).disposition, QuestionDisposition.cancelled);
    expect(first.pending.single.prompt, 'two');
    expect((await scope.run(() => questions.ask('late'))).disposition,
        QuestionDisposition.cancelled);
    first.answer(first.pending.single.id, 'two');
    expect((await two).text, 'two');
    other.cancel();
  });

  test(
      'host cancellation isolates command questions and makes no-cancel handlers cancellable',
      () async {
    final host = Host.start(HostConfig(
        workingDirectory: '.',
        questions: questions,
        providerFactory: (_) => ScriptedProvider([])));
    addTearDown(host.shutdown);
    final connection = host.connect();
    addTearDown(connection.close);
    final results = <QuestionResult>[];
    for (final name in ['one', 'two']) {
      host.commands.publish(Command(
          name: name,
          description: name,
          handler: (_) async {
            results.add(await questions.ask(name));
          }));
    }
    final one = connection.submit('/one'), two = connection.submit('/two');
    expect(connection.status.cancellableWork, hasLength(2));
    final cancelled = connection.status.cancellableWork
        .firstWhere((w) => w.command == 'one')
        .id;
    expect(connection.cancel([cancelled]), isTrue);
    await one;
    expect(results.single.disposition, QuestionDisposition.cancelled);
    expect(first.pending.single.prompt, 'two');
    expect(connection.cancel([cancelled]), isFalse);
    first.answer(first.pending.single.id, 'second');
    await two;
    expect(results.last.text, 'second');
  });

  test('host shutdown settles a waiting command before closing the provider',
      () async {
    final host = Host.start(HostConfig(
        workingDirectory: '.',
        questions: questions,
        providerFactory: (_) => ScriptedProvider([])));
    final connection = host.connect();
    addTearDown(connection.close);
    QuestionResult? answer;
    host.commands.publish(Command(
        name: 'ask',
        description: 'ask',
        handler: (_) async {
          answer = await questions.ask('shutdown');
        }));
    final command = connection.submit('/ask');
    await host.shutdown().timeout(const Duration(seconds: 3));
    await command;
    expect(answer!.disposition, QuestionDisposition.closed);
    expect(connection.status.closed, isTrue);
  });

  for (final direct in [true, false]) {
    test('turn cancellation settles tool questions (direct=$direct)', () async {
      final host = Host.start(HostConfig(
          workingDirectory: '.',
          questions: questions,
          plugins: [_Tools()],
          providerFactory: (_) =>
              ScriptedProvider([_ask('first'), _ask('second')])));
      addTearDown(host.shutdown);
      final connection = host.connect();
      addTearDown(connection.close);
      final started = [Completer<void>(), Completer<void>()];
      final answers = <QuestionResult>[];
      var calls = 0;
      host.session.loop.registerExecutor('ask', (_) async {
        final answer = questions.ask('turn ${calls + 1}');
        started[calls++].complete();
        answers.add(await answer);
        return const ToolResult('done');
      });
      final firstTurn = connection.submit('first');
      await started.first.future;
      final oldId = first.pending.single.id;
      final oldWork = connection.status.cancellableWork.single.id;
      if (direct) {
        host.session.loop.cancel('test direct cancellation');
      } else {
        expect(connection.cancel([oldWork]), isTrue);
      }
      await firstTurn;
      expect(answers.single.disposition, QuestionDisposition.cancelled);
      expect(first.answer(oldId, 'late'), isFalse);
      final secondTurn = connection.submit('second');
      await started.last.future;
      expect(connection.cancel([oldWork]), isFalse);
      expect(first.pending.single.prompt, 'turn 2');
      first.answer(first.pending.single.id, 'second answer');
      await secondTurn;
      expect(answers.last.text, 'second answer');
    });
  }

  test('queued turns retire old questions and get a fresh scope', () async {
    final host = Host.start(HostConfig(
        workingDirectory: '.',
        questions: questions,
        plugins: [_Tools()],
        providerFactory: (_) =>
            ScriptedProvider([_ask('first'), _ask('second')])));
    addTearDown(host.shutdown);
    final connection = host.connect();
    addTearDown(connection.close);
    final started = [Completer<void>(), Completer<void>()];
    final continueOld = Completer<void>();
    late Future<QuestionResult> abandoned, lateAsk;
    QuestionResult? secondAnswer;
    var calls = 0;
    host.session.loop.registerContextExecutor('ask', (_, context) async {
      if (calls++ == 0) {
        abandoned = questions.ask('old question');
        lateAsk =
            continueOld.future.then((_) => questions.ask('late question'));
        started.first.complete();
        await context.whenInputPending;
      } else {
        final answer = questions.ask('new question');
        started.last.complete();
        secondAnswer = await answer;
      }
      return const ToolResult('done');
    });
    final turn = connection.submit('first');
    await started.first.future;
    final oldId = first.pending.single.id;
    expect(connection.offerInput('next'), isTrue);
    await started.last.future;
    expect((await abandoned).disposition, QuestionDisposition.cancelled);
    continueOld.complete();
    expect((await lateAsk).disposition, QuestionDisposition.cancelled);
    expect(first.answer(oldId, 'late answer'), isFalse);
    expect(first.pending.single.prompt, 'new question');
    first.answer(first.pending.single.id, 'new answer');
    await turn;
    expect(secondAnswer!.text, 'new answer');
  });
}
