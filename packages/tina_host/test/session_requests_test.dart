import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';

final class _Provider implements LlmProvider {
  final calls = <StreamController<StreamEvent>>[];
  @override
  String get model => 'controlled';
  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) {
    final call = StreamController<StreamEvent>();
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
    for (final call in calls) unawaited(call.close());
  }
}

final class _PostTurn extends AgentPlugin {
  @override
  String get id => 'test/post-turn';
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> onTurnEnd(TurnContext context) {
    entered.complete();
    return release.future;
  }
}

final class _DetailsFailure extends AgentPlugin {
  @override
  String get id => 'test/details-failure';
  bool fail = true;
  @override
  void sessionChanged(PluginSession session) {
    if (fail) throw StateError('metadata save failed');
  }
}

Future<void> _until(bool Function() ready) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!ready()) {
    if (DateTime.now().isAfter(end)) fail('condition not reached');
    await Future<void>.delayed(Duration.zero);
  }
}

Matcher _error(SessionRequestErrorCode code) =>
    throwsA(isA<SessionRequestError>().having((e) => e.code, 'code', code));

void main() {
  late Host host;
  late _Provider provider;
  late SessionConnection client;
  void start({int limit = 256, List<AgentPlugin> plugins = const []}) {
    provider = _Provider();
    host = Host.start(
        HostConfig(
            workingDirectory: '.',
            providerFactory: (_) => provider,
            plugins: plugins,
            requestHistoryLimit: limit),
        sessionId: 'same-session');
    client = host.connect();
    addTearDown(client.close);
    addTearDown(host.shutdown);
  }

  test(
      'receipt precedes completion; concurrent clients and reconnect execute once',
      () async {
    start();
    final other = host.connect();
    addTearDown(other.close);
    final id = client.requestWindow.id('caller-1');
    final request = client.submitRequest('hello', id: id);
    final initial = request.snapshot;
    expect(initial.state, SessionRequestState.running);
    expect(initial.inputId, isNotNull);
    expect(initial.workId, client.status.cancellableWork.single.id);
    expect(initial.result, isNull);
    final duplicate = other.submitRequest('hello',
        id: SessionRequestId(
            SessionRequestWindow(id.window.epoch, id.window.generation),
            id.value));
    expect(duplicate, same(request));
    client.close();
    final reconnected = host.connect();
    addTearDown(reconnected.close);
    expect(reconnected.submitRequest('hello', id: id), same(request));
    await _until(() => provider.calls.isNotEmpty);
    provider.answer('done');
    final result = await request.completed;
    expect(result.state, SessionRequestState.completed);
    expect(result.result!.detail, 'done');
    expect(reconnected.request(id)!.snapshot, same(result));
    expect(reconnected.submitRequest('hello', id: id), same(request));
    expect(provider.calls, hasLength(1));
    expect(host.session.loop.log.whereType<InputRecordedEntry>(), hasLength(1));
    expect(initial.result, isNull); // Receipt snapshots never mutate.
  });

  test('same ID with a different exact payload is rejected without execution',
      () async {
    start();
    var executions = 0;
    host.commands.publish(
        Command(name: 'once', description: '', handler: (_) => executions++));
    final id = client.requestWindow.id('command');
    final request = client.submitRequest('/once argument', id: id);
    expect(() => client.submitRequest('/once changed', id: id),
        _error(SessionRequestErrorCode.conflict));
    await request.completed;
    expect(() => client.submitRequest(' /once argument', id: id),
        _error(SessionRequestErrorCode.conflict));
    expect(executions, 1);
  });

  test('command failures stay failed on retry, including after detach',
      () async {
    start();
    final release = Completer<void>();
    var executions = 0;
    host.commands.publish(Command(
        name: 'fail',
        description: '',
        handler: (_) async {
          executions++;
          await release.future;
          throw StateError('secret exception detail');
        }));
    final id = client.requestWindow.id('fail');
    final request = client.submitRequest('/fail', id: id);
    client.close();
    release.complete();
    final result = await request.completed;
    expect(result.state, SessionRequestState.failed);
    expect(result.result!.detail, 'Command failed (StateError)');
    final next = host.connect();
    addTearDown(next.close);
    expect(await next.submitRequest('/fail', id: id).completed, same(result));
    expect(executions, 1);
  });

  test('observers can inspect receipts but cannot replay even completed IDs',
      () async {
    start();
    var executions = 0;
    host.commands.publish(
        Command(name: 'once', description: '', handler: (_) => executions++));
    final id = client.requestWindow.id('controller');
    final request = client.submitRequest('/once', id: id);
    final observer = host.connect(role: SessionRole.observer);
    addTearDown(observer.close);
    final denied = throwsA(isA<SessionAccessDenied>());
    expect(observer.request(id), same(request));
    expect(() => observer.submitRequest('/once', id: id), denied);
    await request.completed;
    expect(() => observer.submitRequest('/once', id: id), denied);
    expect(
        () => observer.submitRequest('/once',
            id: observer.requestWindow.id('new')),
        denied);
    expect(executions, 1);
    client.close();
    expect(() => client.submitRequest('/once', id: id), throwsStateError);
  });

  test('steering retries enter the engine queue once and settle per input',
      () async {
    start();
    final first =
        client.submitRequest('first', id: client.requestWindow.id('first'));
    await _until(() => provider.calls.length == 1);
    final id = client.requestWindow.id('second');
    final second = client.submitRequest('second', id: id);
    expect(second.snapshot.state, SessionRequestState.accepted);
    expect(second.snapshot.workId, isNull);
    expect(client.submitRequest('second', id: id), same(second));
    expect(host.session.loop.pendingInputs.single.id, second.snapshot.inputId);
    await _until(() => provider.calls.length == 2);
    expect((await first.completed).terminal, isTrue);
    expect(second.snapshot.state, SessionRequestState.running);
    expect(second.snapshot.workId, isNot(first.snapshot.workId));
    expect(client.cancel([first.snapshot.workId!]), isFalse);
    provider.answer('second reply');
    expect((await second.completed).result!.detail, 'second reply');
    expect(
        host.session.loop.log
            .whereType<InputRecordedEntry>()
            .map((e) => e.text),
        ['first', 'second']);
  });

  for (final shutdown in [false, true]) {
    test(
        '${shutdown ? 'shutdown' : 'cancel'} settles accepted queued inputs without running them',
        () async {
      start();
      final first =
          client.submitRequest('first', id: client.requestWindow.id('first'));
      await _until(() => provider.calls.length == 1);
      final queuedId = client.requestWindow.id('queued');
      final queued = client.submitRequest('queued', id: queuedId);
      final stopping = shutdown ? host.shutdown() : null;
      if (!shutdown) client.cancel([first.snapshot.workId!]);
      expect((await queued.completed).state, SessionRequestState.cancelled);
      expect(queued.snapshot.workId, isNull);
      expect((await first.completed).state, SessionRequestState.cancelled);
      if (stopping != null) await stopping;
      expect(provider.calls, hasLength(1));
      expect(
          host.session.loop.log
              .whereType<InputRecordedEntry>()
              .map((e) => e.text),
          ['first']);
      if (!shutdown)
        expect(client.submitRequest('queued', id: queuedId), same(queued));
    });
  }

  test('persistence failure fails both current and dropped queued receipts',
      () async {
    start();
    host.session.loop.subscribeBatches((entries, event) {
      if (event == LogEvent.appended &&
          entries.any((e) => e is TurnEndedEntry)) {
        throw StateError('disk unavailable');
      }
    });
    final first =
        client.submitRequest('first', id: client.requestWindow.id('first'));
    await _until(() => provider.calls.isNotEmpty);
    final queued =
        client.submitRequest('queued', id: client.requestWindow.id('queued'));
    expect((await first.completed).state, SessionRequestState.failed);
    expect((await queued.completed).state, SessionRequestState.failed);
    expect(host.session.loop.publicationFailed, isTrue);
    expect(provider.calls, hasLength(1));
    expect(client.submitRequest('first', id: first.snapshot.id), same(first));
  });

  test('publication failure at input admission cannot report completion',
      () async {
    start();
    host.session.loop.subscribeBatches((entries, event) {
      if (entries.any((e) => e is InputRecordedEntry)) throw StateError('disk');
    });
    final request =
        client.submitRequest('first', id: client.requestWindow.id('first'));
    expect((await request.completed).state, SessionRequestState.failed);
    expect(provider.calls, isEmpty);
  });

  test('provider failures remain failed when retried', () async {
    start();
    final request =
        client.submitRequest('first', id: client.requestWindow.id('first'));
    await _until(() => provider.calls.isNotEmpty);
    provider.calls.last.addError(StateError('provider failed'));
    expect((await request.completed).state, SessionRequestState.failed);
    expect(
        client.submitRequest('first', id: request.snapshot.id), same(request));
    expect(provider.calls, hasLength(1));
  });

  test('session metadata failures cannot publish a successful input receipt',
      () async {
    final plugin = _DetailsFailure();
    start(plugins: [plugin]);
    final request =
        client.submitRequest('hello', id: client.requestWindow.id('metadata'));
    await _until(() => provider.calls.isNotEmpty);
    provider.answer('done');
    final result = await request.completed;
    plugin.fail = false;
    expect(result.state, SessionRequestState.failed);
    expect(
        client.submitRequest('hello', id: request.snapshot.id), same(request));
    expect(provider.calls, hasLength(1));
  });

  test('busy command rejection and unknown commands remain rejected on retry',
      () async {
    start();
    var executions = 0;
    host.commands.publish(
        Command(name: 'idle', description: '', handler: (_) => executions++));
    final first =
        client.submitRequest('first', id: client.requestWindow.id('first'));
    final rejected =
        client.submitRequest('/idle', id: client.requestWindow.id('idle'));
    final missing =
        client.submitRequest('/later', id: client.requestWindow.id('missing'));
    expect(rejected.snapshot.state, SessionRequestState.rejected);
    expect(missing.snapshot.state, SessionRequestState.rejected);
    await _until(() => provider.calls.isNotEmpty);
    provider.answer('done');
    await first.completed;
    await _until(() => !client.status.running);
    host.commands.publish(
        Command(name: 'later', description: '', handler: (_) => executions++));
    expect(client.submitRequest('/idle', id: rejected.snapshot.id),
        same(rejected));
    expect(
        client.submitRequest('/later', id: missing.snapshot.id), same(missing));
    expect(executions, 0);
  });

  test('turn-transition input is explicitly rejected and cannot hang',
      () async {
    final post = _PostTurn();
    start(plugins: [post]);
    final first =
        client.submitRequest('first', id: client.requestWindow.id('first'));
    await _until(() => provider.calls.isNotEmpty);
    provider.answer('done');
    await post.entered.future;
    expect(first.snapshot.state, SessionRequestState.running);
    final late =
        client.submitRequest('late', id: client.requestWindow.id('late'));
    expect(late.snapshot.state, SessionRequestState.rejected);
    expect(host.session.loop.pendingInputCount, 0);
    post.release.complete();
    await first.completed;
    expect(client.submitRequest('late', id: late.snapshot.id), same(late));
  });

  test('plugin-driven turns also settle retryable steering inputs', () async {
    start();
    host.commands.publish(Command(
        name: 'workflow',
        description: '',
        handler: (_) async {
          await host.session.loop.runTurn(const Input('node', id: 'node'));
        }));
    final command = client.submitRequest('/workflow',
        id: client.requestWindow.id('command'));
    await _until(() => provider.calls.length == 1);
    final input =
        client.submitRequest('steer', id: client.requestWindow.id('input'));
    await _until(() => provider.calls.length == 2);
    provider.answer('done');
    expect((await input.completed).state, SessionRequestState.completed);
    expect((await command.completed).state, SessionRequestState.completed);
  });

  test('command cancellation and stale cancellation preserve request identity',
      () async {
    start();
    late Completer<void> release;
    var executions = 0, cancellations = 0;
    host.commands.publish(Command(
        name: 'wait',
        description: '',
        allowWhileRunning: true,
        handler: (_) {
          executions++;
          return (release = Completer<void>()).future;
        },
        cancel: () {
          cancellations++;
          release.complete();
        }));
    final request =
        client.submitRequest('/wait', id: client.requestWindow.id('wait'));
    final duplicate =
        client.submitRequest('/wait', id: client.requestWindow.id('different'));
    expect(duplicate.snapshot.state, SessionRequestState.rejected);
    expect(client.cancel([request.snapshot.workId!]), isTrue);
    expect((await request.completed).state, SessionRequestState.cancelled);
    final next =
        client.submitRequest('/wait', id: client.requestWindow.id('next'));
    expect(
        client.submitRequest('/wait', id: request.snapshot.id), same(request));
    expect(client.cancel([request.snapshot.workId!]), isFalse);
    expect(cancellations, 1);
    client.cancel([next.snapshot.workId!]);
    await next.completed;
    expect(executions, 2);
  });

  test('bounded eviction expires old IDs without evicting active requests',
      () async {
    start(limit: 2);
    final release = Completer<void>();
    var executions = 0;
    host.commands.publish(
        Command(name: 'wait', description: '', handler: (_) => release.future));
    host.commands.publish(
        Command(name: 'once', description: '', handler: (_) => executions++));
    final window = client.requestWindow;
    final active = client.submitRequest('/wait', id: window.id('active'));
    final old = client.submitRequest('/once', id: window.id('old'));
    await old.completed;
    final newRequest = client.submitRequest('/once', id: window.id('new'));
    await newRequest.completed;
    expect(client.requestWindow.generation, greaterThan(window.generation));
    expect(client.submitRequest('/wait', id: active.snapshot.id), same(active));
    expect(() => client.submitRequest('/once', id: old.snapshot.id),
        _error(SessionRequestErrorCode.expired));
    expect(() => client.request(old.snapshot.id),
        _error(SessionRequestErrorCode.expired));
    expect(() => client.submitRequest('/once', id: window.id('never-sent')),
        _error(SessionRequestErrorCode.expired));
    expect(client.request(client.requestWindow.id('unknown')), isNull);
    for (var i = 0; i < 20; i++) {
      await client
          .submitRequest('/once', id: client.requestWindow.id('bounded-$i'))
          .completed;
      final view = client.attach();
      expect(view.initial.requests, hasLength(2));
      view.close();
    }
    expect(client.request(active.snapshot.id), same(active));
    release.complete();
    await active.completed;
    expect(executions, 22);
  });

  test('all-active capacity refuses work and still permits duplicate retries',
      () async {
    start(limit: 1);
    final release = Completer<void>();
    var executions = 0;
    host.commands.publish(Command(
        name: 'wait',
        description: '',
        handler: (_) {
          executions++;
          return release.future;
        }));
    final first =
        client.submitRequest('/wait', id: client.requestWindow.id('first'));
    final id = client.requestWindow.id('second');
    expect(() => client.submitRequest('/wait', id: id),
        _error(SessionRequestErrorCode.capacity));
    expect(client.request(id), isNull);
    expect(client.submitRequest('/wait', id: first.snapshot.id), same(first));
    expect(executions, 1);
    release.complete();
    await first.completed;
    expect((await client.submitRequest('/wait', id: id).completed).state,
        SessionRequestState.completed);
    expect(executions, 2);
  });

  test('receipt is registered before a command handler can reenter submission',
      () async {
    start();
    final id = client.requestWindow.id('reentrant');
    var executions = 0;
    SessionRequest? duplicate;
    host.commands.publish(Command(
        name: 'once',
        description: '',
        handler: (_) {
          executions++;
          duplicate = client.submitRequest('/once', id: id);
        }));
    final receipt = client.submitRequest('/once', id: id);
    expect(duplicate, same(receipt));
    await receipt.completed;
    expect(executions, 1);
  });

  test(
      'shutdown cancels cancellable commands and drains uncancellable commands',
      () async {
    start();
    final cancelRelease = Completer<void>(), finishRelease = Completer<void>();
    host.commands.publish(Command(
        name: 'cancel',
        description: '',
        handler: (_) => cancelRelease.future,
        cancel: cancelRelease.complete));
    host.commands.publish(Command(
        name: 'finish', description: '', handler: (_) => finishRelease.future));
    final cancelled =
        client.submitRequest('/cancel', id: client.requestWindow.id('cancel'));
    final finished =
        client.submitRequest('/finish', id: client.requestWindow.id('finish'));
    final shutdown = host.shutdown();
    expect((await cancelled.completed).state, SessionRequestState.cancelled);
    expect(finished.snapshot.state, SessionRequestState.running);
    finishRelease.complete();
    await shutdown;
    expect((await finished.completed).state, SessionRequestState.completed);
  });

  test(
      'runtime epoch mismatch refuses retry with the same persisted session ID',
      () async {
    start();
    final old = client.requestWindow.id('old');
    final reopened = Host.start(
        HostConfig(workingDirectory: '.', providerFactory: (_) => _Provider()),
        sessionId: 'same-session');
    addTearDown(reopened.shutdown);
    final next = reopened.connect();
    addTearDown(next.close);
    expect(next.status.id, client.status.id);
    expect(() => next.submitRequest('hello', id: old),
        _error(SessionRequestErrorCode.epochMismatch));
    expect(
        () => next.request(old), _error(SessionRequestErrorCode.epochMismatch));
    expect(reopened.session.loop.log, isEmpty);
  });

  test('attachment snapshots expose immutable receipts and their completion',
      () async {
    start();
    final observer = host.connect(role: SessionRole.observer);
    addTearDown(observer.close);
    final request =
        client.submitRequest('hello', id: client.requestWindow.id('hello'));
    final attachment = observer.attach();
    expect(attachment.initial.requests.single.id, request.snapshot.id);
    expect(() => attachment.initial.requests.clear(), throwsUnsupportedError);
    await _until(() => provider.calls.isNotEmpty);
    provider.answer('done');
    await request.completed;
    SessionSnapshot snapshot;
    do {
      snapshot = (await attachment.next())!.snapshot;
    } while (!snapshot.requests.single.terminal);
    expect(snapshot.requests.single.state, SessionRequestState.completed);
    expect(attachment.initial.requests.single.terminal, isFalse);
  });

  test('invalid and oversized IDs and payloads cannot reserve receipt capacity',
      () {
    start(limit: 1);
    for (final value in ['', 'x' * 129]) {
      expect(
          () =>
              client.submitRequest('hello', id: client.requestWindow.id(value)),
          throwsArgumentError);
    }
    expect(
        () => client.submitRequest('x' * 1048577,
            id: client.requestWindow.id('large')),
        throwsArgumentError);
    final view = client.attach();
    expect(view.initial.requests, isEmpty);
    view.close();
  });

  test('large completion detail is bounded with explicit truncation', () async {
    start();
    final request =
        client.submitRequest('hello', id: client.requestWindow.id('large'));
    await _until(() => provider.calls.isNotEmpty);
    provider.answer('x' * 20000);
    final result = await request.completed;
    expect(result.result!.detail.length, 16384);
    expect(result.resultTruncated, isTrue);
    expect(
        host.session.loop.log
            .whereType<MessageAppendedEntry>()
            .last
            .message
            .content
            .whereType<TextBlock>()
            .single
            .text
            .length,
        20000);
  });
}
