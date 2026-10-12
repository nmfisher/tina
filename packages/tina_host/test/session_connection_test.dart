import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';

final class _Provider implements LlmProvider {
  final requests = <StreamController<StreamEvent>>[];
  int closes = 0;
  @override
  String get model => 'controlled';
  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) {
    final request = StreamController<StreamEvent>();
    requests.add(request);
    return request.stream;
  }

  void answer(String text) {
    requests.last.add(
        MessageComplete(content: [TextBlock(text)], stopReason: 'end_turn'));
    unawaited(requests.last.close());
  }

  @override
  void close() {
    closes++;
    for (final request in requests) unawaited(request.close());
  }
}

Future<void> _until(bool Function() predicate) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate()) {
    if (DateTime.now().isAfter(end)) fail('condition did not become true');
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late Host host;
  late _Provider provider;
  setUp(() {
    provider = _Provider();
    host = Host.start(HostConfig(
        workingDirectory: '/workspace',
        model: 'controlled',
        providerFactory: (_) => provider));
  });
  tearDown(() => host.shutdown());

  for (final (line, argument) in [
    ('/example value', 'value'),
    ('/example   several words  ', 'several words'),
    ('/example', ''),
    ('  /example  ', ''),
    ('!printf "one two" | cat', 'printf "one two" | cat'),
  ]) {
    test('command dispatch preserves arguments: $line', () async {
      final client = host.connect();
      addTearDown(client.close);
      String? received;
      host.commands.publish(Command(
          name: 'example',
          description: 'example',
          inputPrefix: '!',
          handler: (value) => received = value));
      expect(client.commandFor(line)?.argument, argument);
      await client.submit(line);
      expect(received, argument);
      expect(provider.requests, isEmpty);
    });
  }

  test('empty input is ignored and bare slash is reported without a model turn',
      () async {
    final client = host.connect();
    addTearDown(client.close);
    expect((await client.submit('   ')).notice, isNull);
    expect((await client.submit('/')).notice, 'unknown command: /');
    expect(client.commandFor('ordinary input'), isNull);
    expect(client.commandFor('!unregistered prefix'), isNull);
    expect(provider.requests, isEmpty);
  });

  test('shutdown drains other work even when a cancellation callback throws',
      () async {
    final local = Host.start(
        HostConfig(workingDirectory: '.', providerFactory: (_) => _Provider()));
    final client = local.connect();
    final release = Completer<void>();
    local.commands.publish(Command(
        name: 'broken',
        description: 'broken',
        allowWhileRunning: true,
        handler: (_) => release.future,
        cancel: () => throw StateError('cancellation failed')));
    final work = client.offerCommand('/broken')!;
    final shutdown = local.shutdown();
    final failure = expectLater(shutdown, throwsStateError);
    expect(client.status.closed, isFalse);
    release.complete();
    await work;
    await failure;
    expect(client.status.closed, isTrue);
    client.close();
  });

  test(
      'metadata, prefix parsing and completion retain live command registration',
      () async {
    final client = host.connect();
    addTearDown(client.close);
    final before = client.commands;
    String? received;
    host.commands.publish(Command(
        name: 'shell',
        description: 'user shell',
        inputPrefix: '!',
        handler: (argument) => received = argument,
        complete: (_) => ['one', 'two']));
    expect(before, isEmpty);
    expect(client.commands.single.name, 'shell');
    expect(() => client.commands.clear(), throwsUnsupportedError);
    expect(
        client.commandFor(' !echo "a b" | cat ')?.argument, 'echo "a b" | cat');
    expect(await client.completeCommand('shell', ''), ['one', 'two']);
    await client.submit('!echo "a b" | cat');
    expect(received, 'echo "a b" | cat');
    expect((await client.submit('/missing arg')).detail,
        'unknown command: /missing');
    expect(client.offerInput('!echo hi'), isFalse);
    expect(provider.requests, isEmpty);
  });

  test('closing one connection preserves shared work and the other observer',
      () async {
    final first = host.connect(), second = host.connect();
    addTearDown(first.close);
    addTearDown(second.close);
    final states = <SessionStatus>[];
    second.listen(states.add);
    final work = first.submit('hello');
    await _until(() => provider.requests.isNotEmpty && states.last.running);
    first.close();
    expect(first.offerInput('late'), isFalse);
    expect(first.cancel(second.status.cancellableWork.map((work) => work.id)),
        isFalse);
    provider.answer('completed');
    expect((await work).stopReason, StopReason.complete);
    await _until(() => !states.last.running);
    expect(second.inputHistory, ['hello']);
    expect(provider.closes, 0);
  });

  test('stale turn cancellation cannot stop a steered successor', () async {
    final first = host.connect(), second = host.connect();
    addTearDown(first.close);
    addTearDown(second.close);
    final work = first.submit('first');
    await _until(() => provider.requests.length == 1);
    final old = first.status.cancellableWork.single.id;
    await expectLater(second.submit('concurrent'), throwsStateError);
    expect(second.offerInput('  replacement  '), isTrue);
    await _until(() => provider.requests.length == 2);
    expect(second.status.cancellableWork.single.id, isNot(old));
    expect(second.cancel([old]), isFalse);
    expect(second.status.running, isTrue);
    provider.answer('second answer');
    expect((await work).stopReason, StopReason.complete);
    expect(second.inputHistory, ['first', '  replacement  ']);
  });

  test('commands and cancellation are shared between connections', () async {
    final first = host.connect(), second = host.connect();
    addTearDown(first.close);
    addTearDown(second.close);
    late Completer<void> release;
    var cancellations = 0;
    host.commands.publish(Command(
        name: 'wait',
        description: 'wait',
        allowWhileRunning: true,
        handler: (_) => (release = Completer<void>()).future,
        cancel: () {
          cancellations++;
          release.complete();
        }));
    final command = first.offerCommand('/wait')!;
    final old = second.status.cancellableWork.single.id;
    expect((await second.offerCommand('/wait'))!.notice,
        'A wait command is already running in this session.');
    expect(second.status.cancellableWork.single.id, old);
    expect(second.cancel([old]), isTrue);
    await command;
    final next = second.offerCommand('/wait')!;
    expect(first.cancel([old]), isFalse);
    expect(cancellations, 1);
    first.cancel(second.status.cancellableWork.map((work) => work.id));
    await next;
    expect(cancellations, 2);
  });

  test('plugin commands that drive the loop retire completed turn IDs',
      () async {
    final client = host.connect();
    addTearDown(client.close);
    host.commands.publish(Command(
        name: 'workflow',
        description: 'run a workflow node on the existing loop',
        handler: (_) async {
          await host.session.loop.runTurn(Input('node', id: 'node'));
        }));
    final command = client.submit('/workflow');
    await _until(() => provider.requests.isNotEmpty);
    final id = client.status.cancellableWork.single.id;
    provider.answer('done');
    await command;
    expect(client.status.running, isFalse);
    expect(client.status.canCancel, isFalse);
    expect(client.cancel([id]), isFalse);
  });

  test('direct host turns are observed and failing listeners are isolated',
      () async {
    final client = host.connect();
    addTearDown(client.close);
    var failures = 0;
    client.listen((status) {
      if (status.running) {
        failures++;
        throw StateError('bad renderer');
      }
    });
    final observed = <SessionStatus>[];
    final unlisten = client.listen(observed.add);
    final turn = host.send('direct input');
    await _until(() => provider.requests.isNotEmpty && observed.last.running);
    provider.answer('done');
    await turn;
    await _until(() => !observed.last.running);
    expect(failures, 1);
    unlisten();
    final count = observed.length;
    await host.shutdown();
    await Future<void>.delayed(Duration.zero);
    expect(observed, hasLength(count));
  });

  test('shutdown rejects input and waits for command cleanup before closing',
      () async {
    final client = host.connect();
    addTearDown(client.close);
    final cancelled = Completer<void>(), cleanup = Completer<void>();
    host.commands.publish(Command(
        name: 'job',
        description: 'job',
        allowWhileRunning: true,
        cancel: cancelled.complete,
        handler: (_) async {
          await cancelled.future;
          await cleanup.future;
        }));
    final turn = client.submit('model turn');
    await _until(() => provider.requests.isNotEmpty);
    final job = client.offerCommand('/job')!;
    var stopped = false;
    final shutdown = host.shutdown().then((_) => stopped = true);
    await cancelled.future;
    expect(client.status.stopping, isTrue);
    expect(client.offerInput('new'), isFalse);
    await expectLater(client.submit('new'), throwsStateError);
    expect(client.offerCommand('/job'), isNull);
    expect(host.close, throwsStateError);
    expect(provider.closes, 0);
    expect(stopped, isFalse);
    cleanup.complete();
    await Future.wait([shutdown, job, turn]);
    expect(provider.closes, 1);
    expect(client.status.closed, isTrue);
    expect(host.session.loop.log.whereType<TurnEndedEntry>(), hasLength(1));
    await host.shutdown();
    expect(provider.closes, 1);
  });

  test('shutdown drains accepted completion and rejects new completion',
      () async {
    final client = host.connect();
    addTearDown(client.close);
    final completed = Completer<List<String>>();
    host.commands.publish(Command(
        name: 'lookup',
        description: 'lookup',
        handler: (_) {},
        complete: (_) => completed.future));
    final completion = client.completeCommand('lookup', '');
    final shutdown = host.shutdown();
    expect(client.status.stopping, isTrue);
    expect(provider.closes, 0);
    await expectLater(client.completeCommand('lookup', ''), throwsStateError);
    client.close();
    completed.complete(['result']);
    expect(await completion, ['result']);
    await shutdown;
    expect(provider.closes, 1);
  });

  test('reentrant shutdown shares one future and cancels each command once',
      () async {
    final client = host.connect();
    addTearDown(client.close);
    final released = Completer<void>();
    Future<void>? reentrant;
    var cancellations = 0;
    host.commands.publish(Command(
        name: 'job',
        description: 'job',
        handler: (_) => released.future,
        cancel: () {
          cancellations++;
          reentrant = host.shutdown();
          released.complete();
        }));
    final job = client.submit('/job');
    final shutdown = host.shutdown();
    expect(identical(reentrant, shutdown), isTrue);
    await Future.wait([job, shutdown]);
    expect(cancellations, 1);
    expect(provider.closes, 1);
  });
}
