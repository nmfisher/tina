import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';

final class _Plugin extends AgentPlugin {
  @override
  String get id => 'test/worker';
  bool closed = false;
  @override
  void closeSession() => closed = true;
}

const _ok = SessionResult(stopReason: StopReason.complete);

void main() {
  Host start(SessionOperationHandler handler,
      {int limit = 256, LlmProvider? provider, _Plugin? plugin}) {
    final host = Host.start(HostConfig(
      workingDirectory: '.',
      providerFactory: (_) =>
          provider ?? ScriptedProvider([scriptedReply('done')]),
      plugins: [plugin ?? _Plugin()],
      operationsFor: (_) => {'run': SessionOperation(handler)},
      requestHistoryLimit: limit,
    ));
    addTearDown(host.shutdown);
    return host;
  }

  test('two clients observe one operation across turns and detach', () async {
    final pause = Completer<void>(), betweenTurns = Completer<void>();
    var calls = 0, idle = 0;
    final host = start((plugin, arguments, context) async {
      calls++;
      await context.send('first');
      context.writeLine('first reply');
      betweenTurns.complete();
      await pause.future;
      context.writeLine('judgment complete');
      return _ok;
    });
    host.onIdle = () => idle++;
    final client = host.connect(),
        observer = host.connect(role: SessionRole.observer);
    addTearDown(observer.close);
    final id = client.requestWindow.id('goal');
    final request = client.submitOperation('test/worker', 'run', id: id);
    final workId = request.snapshot.workId!;
    await betweenTurns.future;
    client.close();
    final snapshot = observer.attach().initial;
    expect(snapshot.status.busy, isTrue);
    expect(snapshot.status.running, isFalse);
    expect(snapshot.status.acceptsInput, isFalse);
    expect(snapshot.activeWork.single.id, workId);
    expect(snapshot.activeWork.single.plugin, 'test/worker');
    expect(snapshot.activeWork.single.operation, 'run');
    expect(observer.request(id), same(request));
    expect(observer.output(id).entries.single.text, 'first reply');
    expect(idle, 0);
    expect(() => observer.submitOperation('test/worker', 'run', id: id),
        throwsA(isA<SessionAccessDenied>()));
    expect(
        () => observer.cancel([workId]), throwsA(isA<SessionAccessDenied>()));
    final controller = host.connect();
    addTearDown(controller.close);
    expect(controller.submitOperation('test/worker', 'run', id: id),
        same(request));
    expect(
        (await controller
                .submitRequest('interloper',
                    id: controller.requestWindow.id('input'))
                .completed)
            .state,
        SessionRequestState.rejected);
    expect(() => host.switchModel('new'), throwsStateError);
    expect(() => host.detachPlugin('test/worker'), throwsStateError);
    pause.complete();
    expect((await request.completed).state, SessionRequestState.completed);
    expect(observer.output(id, afterSeq: 0).entries.single.text,
        'judgment complete');
    expect(controller.status.busy, isFalse);
    expect(idle, 1);
    expect(calls, 1);
  });

  test(
      'synchronous controls preserve the foreground lease and enforce scheduling',
      () async {
    final release = Completer<void>(), between = Completer<void>();
    var controls = 0;
    final host = Host.start(HostConfig(
      workingDirectory: '.',
      providerFactory: (_) => ScriptedProvider([scriptedReply('answer')]),
      plugins: [_Plugin()],
      operationsFor: (_) => {
        'run': SessionOperation((plugin, args, context) async {
          await context.send('first');
          between.complete();
          await release.future;
          return _ok;
        }),
        'control': SessionOperation.control((plugin, args) {
          controls++;
          return _ok;
        }, allowWhileRunning: true),
        'idle': SessionOperation.control((plugin, args) {
          controls++;
          return _ok;
        }),
      },
    ));
    addTearDown(host.shutdown);
    final client = host.connect(), other = host.connect();
    addTearDown(other.close);
    final foreground = client.submitOperation('test/worker', 'run',
        id: client.requestWindow.id('foreground'));
    await between.future;
    final workId = foreground.snapshot.workId!;
    client.close();
    final id = other.requestWindow.id('control');
    final control = other.submitOperation('test/worker', 'control', id: id);
    expect(control.snapshot.state, SessionRequestState.completed,
        reason: 'Control effects and their receipts settle synchronously');
    expect(
        other.submitOperation('test/worker', 'control', id: id), same(control));
    expect(controls, 1);
    expect(
        (await other
                .submitOperation('test/worker', 'idle',
                    id: other.requestWindow.id('blocked'))
                .completed)
            .state,
        SessionRequestState.rejected);
    final attachment = other.attach();
    expect(attachment.initial.status.busy, true);
    expect(attachment.initial.status.running, false);
    expect(attachment.initial.activeWork.single.id, workId);
    attachment.close();
    expect(other.cancel([control.snapshot.workId!]), false);
    release.complete();
    await foreground.completed;
    expect(
        (await other
                .submitOperation('test/worker', 'idle',
                    id: other.requestWindow.id('idle'))
                .completed)
            .state,
        SessionRequestState.completed);
    expect(controls, 2);
  });

  test('operation cancellation survives detach and cannot cancel a successor',
      () async {
    final contexts = <SessionOperationContext>[];
    final host = start((_, arguments, context) async {
      contexts.add(context);
      await context.whenCancelled;
      return _ok;
    });
    final client = host.connect(), other = host.connect();
    addTearDown(other.close);
    final request = client.submitOperation('test/worker', 'run',
        id: client.requestWindow.id('first'));
    final old = request.snapshot.workId!;
    client.close();
    expect(other.cancel([old]), isTrue);
    expect((await request.completed).state, SessionRequestState.cancelled);
    final successor = other.submitOperation('test/worker', 'run',
        id: other.requestWindow.id('second'));
    expect(other.cancel([old]), isFalse);
    expect(contexts.last.cancelled, isFalse);
    expect(() => contexts.first.writeLine('late'), throwsStateError);
    await expectLater(contexts.first.send('late'), throwsStateError);
    other.cancel([successor.snapshot.workId!]);
    await successor.completed;
  });

  test('shutdown cancels operation questions and drains cleanup before unload',
      () async {
    final cleaning = Completer<void>(), release = Completer<void>();
    final plugin = _Plugin();
    late Host host;
    host = start((_, arguments, context) async {
      final result = await host.questions.ask('Proceed?');
      expect(result.disposition, QuestionDisposition.cancelled);
      await context.whenCancelled;
      cleaning.complete();
      await release.future;
      expect(plugin.closed, isFalse);
      return _ok;
    }, plugin: plugin);
    final client = host.connect();
    addTearDown(client.close);
    final request = client.submitOperation('test/worker', 'run',
        id: client.requestWindow.id('shutdown'));
    final stopping = host.shutdown();
    await cleaning.future;
    expect(client.status.busy, isTrue);
    expect(plugin.closed, isFalse);
    expect(request.snapshot.terminal, isFalse);
    release.complete();
    await stopping;
    expect((await request.completed).state, SessionRequestState.cancelled);
    expect(plugin.closed, isTrue);
  });

  test('arguments are frozen, canonical retries deduplicate, IDs bind the kind',
      () async {
    final release = Completer<void>();
    Map<String, Object?>? captured;
    final host = start((_, arguments, context) async {
      captured = arguments;
      await release.future;
      return _ok;
    });
    final client = host.connect();
    addTearDown(client.close);
    final id = client.requestWindow.id('identity');
    final args = <String, Object?>{
      'a': 1,
      'b': ['old']
    };
    final request =
        client.submitOperation('test/worker', 'run', arguments: args, id: id);
    (args['b'] as List)[0] = 'new';
    expect(captured!['b'], ['old']);
    expect(() => (captured!['b'] as List).add('bad'), throwsUnsupportedError);
    expect(
        client.submitOperation('test/worker', 'run',
            arguments: {
              'b': ['old'],
              'a': 1
            },
            id: id),
        same(request));
    final conflict = throwsA(isA<SessionRequestError>()
        .having((e) => e.code, 'code', SessionRequestErrorCode.conflict));
    expect(
        () => client.submitOperation('test/worker', 'run',
            arguments: args, id: id),
        conflict);
    expect(
        () => client.submitOperation('test/worker', 'other',
            arguments: args, id: id),
        conflict);
    expect(
        () => client.submitRequest(jsonEncode(['test/worker', 'run', captured]),
            id: id),
        conflict);
    release.complete();
    await request.completed;
  });

  test(
      'output is bounded, immutable and explicitly reports truncation and loss',
      () async {
    final host = start((_, arguments, context) async {
      for (var i = 0; i < 150; i++) context.writeLine('line $i');
      return _ok;
    }, limit: 1);
    final client = host.connect();
    addTearDown(client.close);
    final id = client.requestWindow.id('output');
    await client.submitOperation('test/worker', 'run', id: id).completed;
    final page = client.output(id);
    expect(page.missed, isTrue);
    expect(page.entries, hasLength(128));
    expect(page.throughSeq, 149);
    expect(() => page.entries.clear(), throwsUnsupportedError);
    expect(client.output(id, afterSeq: 148).entries.single.text, 'line 149');
    expect(client.output(id, afterSeq: 149).missed, isFalse);
    await client
        .submitOperation('test/worker', 'run',
            id: client.requestWindow.id('evict'))
        .completed;
    expect(
        () => client.output(id),
        throwsA(isA<SessionRequestError>()
            .having((e) => e.code, 'code', SessionRequestErrorCode.expired)));
    final large = start((_, arguments, context) async {
      context.writeLine('x' * 70000, error: true);
      return _ok;
    }).connect();
    addTearDown(large.close);
    final largeId = large.requestWindow.id('large');
    await large.submitOperation('test/worker', 'run', id: largeId).completed;
    final output = large.output(largeId).entries.single;
    expect(output.truncated, isTrue);
    expect(output.error, isTrue);
    expect(output.text.length, 65536);
  });

  test('failures and unavailable operation admissions retain their result',
      () async {
    final host =
        start((_, arguments, context) async => throw StateError('secret'));
    final client = host.connect();
    addTearDown(client.close);
    final id = client.requestWindow.id('fail');
    final request = client.submitOperation('test/worker', 'run', id: id);
    final result = await request.completed;
    expect(result.state, SessionRequestState.failed);
    expect(result.result!.detail, 'Operation failed (StateError)');
    expect(client.submitOperation('test/worker', 'run', id: id), same(request));
    final missing = client.submitOperation('test/missing', 'run',
        id: client.requestWindow.id('missing'));
    expect((await missing.completed).state, SessionRequestState.rejected);
    expect(
        () => client.submitOperation('test/worker', 'run',
            arguments: {'value': Object()},
            id: client.requestWindow.id('object')),
        throwsArgumentError);
    final cyclic = <String, Object?>{};
    cyclic['self'] = cyclic;
    expect(
        () => client.submitOperation('test/worker', 'run',
            arguments: cyclic, id: client.requestWindow.id('cycle')),
        throwsArgumentError);
  });

  test('live plugin changes wait through the entire operation', () async {
    final release = Completer<void>();
    final plugin = _Plugin();
    final host = start((_, arguments, context) async {
      await context.send('work');
      await release.future;
      return _ok;
    }, plugin: plugin);
    final registry = PluginRegistry<void>()
      ..register('test/worker', (_) => _Plugin(),
          description: 'Work', live: true);
    final manager =
        PluginManager<void>(host: host, registry: registry, context: null);
    final client = host.connect();
    addTearDown(client.close);
    final request = client.submitOperation('test/worker', 'run',
        id: client.requestWindow.id('live'));
    manager.select([]);
    expect(manager.waitingForIdle, isTrue);
    expect(plugin.closed, isFalse);
    release.complete();
    await request.completed;
    expect(plugin.closed, isTrue);
    expect(manager.waitingForIdle, isFalse);
  });

  test('returning from a handler cannot orphan an unawaited turn', () async {
    late SessionOperationContext retained;
    final host = start((_, arguments, context) async {
      retained = context;
      unawaited(context.send('abandoned'));
      return _ok;
    });
    final client = host.connect();
    addTearDown(client.close);
    final request = client.submitOperation('test/worker', 'run',
        id: client.requestWindow.id('abandoned'));
    final result = await request.completed;
    expect(result.state, SessionRequestState.failed);
    expect(result.result!.detail, 'Operation handler did not await its turn');
    expect(client.status.busy, isFalse);
    expect(host.session.loop.running, isFalse);
    await expectLater(retained.send('late'), throwsStateError);
  });
}
