import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_host_interface.dart';
import '../helpers/memory_session_store.dart';

class Router implements InputRouter {
  final Future<InputRoute?> Function(InputContext) callback;
  Router(this.callback);
  @override
  Future<InputRoute?> route(InputContext input) => callback(input);
}

class Handler implements InputHandler {
  final Future<String> Function(InputContext, InputRoute) callback;
  Handler(this.callback);
  @override
  Future<String> handle(InputContext input, InputRoute route) =>
      callback(input, route);
}

void main() {
  late PluginScope scope;
  late InputRoutes routes;
  late FakeHostInterface host;
  late SessionRecorder recorder;
  late MemorySessionStore store;
  late Completer<void> cancel;
  late List<Message> history;
  Registration register(String id, Object value) =>
      scope.registerContribution(pluginId: 'test', id: id, contribution: value);
  Future<InputOutcome> run() => routes.run(
    text: 'hello',
    conversationId: 'conversation',
    history: history,
    host: host,
    cancelSignal: cancel.future,
    recorder: recorder,
  );
  setUp(() async {
    scope = PluginScope('test');
    routes = InputRoutes(scope);
    host = FakeHostInterface();
    store = MemorySessionStore();
    final session = await store.createSession(providerId: 'test');
    final conversation = await store.createConversation(session);
    recorder = SessionRecorder(store, session, conversation, providerId: 'test')
      ..attach(session, conversation);
    cancel = Completer<void>();
    history = [];
  });
  tearDown(() async {
    await scope.dispose();
    await host.dispose();
  });

  test('no routers or all passing leaves transcript untouched', () async {
    expect(await run(), InputOutcome.pass);
    register('pass', Router((_) async => null));
    expect(await run(), InputOutcome.pass);
    expect(history, isEmpty);
    expect(
      await store.loadConversation(recorder.sessionId, recorder.conversationId),
      isEmpty,
    );
  });

  test('already cancelled input does not enter a plugin', () async {
    var calls = 0;
    register(
      'route',
      Router((_) async {
        calls++;
        return null;
      }),
    );
    cancel.complete();
    expect(await run(), InputOutcome.cancelled);
    expect(calls, 0);
  });

  test(
    'first matching router selects a named handler and records original input once',
    () async {
      final order = <String>[];
      register(
        'one',
        Router((input) async {
          order.add('one');
          return null;
        }),
      );
      register(
        'two',
        Router((input) async {
          order.add('two');
          expect(input.text, 'hello');
          expect(input.conversationId, 'conversation');
          return InputRoute('reply', data: {'note': 'test'});
        }),
      );
      register('three', Router((_) async => throw StateError('must not run')));
      register(
        'reply',
        Handler((input, route) async {
          final saved = await store.loadConversation(
            recorder.sessionId,
            recorder.conversationId,
          );
          expect(saved.single.role, Role.user);
          expect(route.data['note'], 'test');
          return 'handled';
        }),
      );
      expect(await run(), InputOutcome.handled);
      expect(order, ['one', 'two']);
      expect(history.map((m) => m.role), [Role.user, Role.assistant]);
      final saved = await store.loadConversation(
        recorder.sessionId,
        recorder.conversationId,
      );
      expect(saved.map((m) => m.toJson()), history.map((m) => m.toJson()));
      expect(host.sink.texts.join(), 'handled');
    },
  );

  test('routers receive detached history', () async {
    history.add(Message(role: Role.user, content: [TextBlock('old')]));
    register(
      'read',
      Router((input) async {
        expect(identical(input.history.first, history.first), isFalse);
        expect(
          identical(input.history.first.content, history.first.content),
          isFalse,
        );
        expect(() => input.history.clear(), throwsUnsupportedError);
        return null;
      }),
    );
    expect(await run(), InputOutcome.pass);
    expect(history.single.content.whereType<TextBlock>().single.text, 'old');
  });

  for (final stage in ['router', 'handler']) {
    test(
      'cancellation interrupts stalled $stage and ignores late reply',
      () async {
        final started = Completer<InputContext>();
        final release = Completer<void>();
        register(
          'route',
          Router((input) async {
            if (stage == 'router') {
              started.complete(input);
              await release.future;
            }
            return InputRoute('reply');
          }),
        );
        register(
          'reply',
          Handler((input, route) async {
            if (stage == 'handler') {
              started.complete(input);
              await release.future;
            }
            return 'late reply';
          }),
        );
        final pending = run();
        final context = await started.future;
        cancel.complete();
        expect(
          await pending.timeout(const Duration(seconds: 1)),
          InputOutcome.cancelled,
        );
        expect(context.isCancelled, isTrue);
        final before = history.map((m) => m.toJson()).toList();
        release.complete();
        await Future<void>.delayed(Duration.zero);
        expect(history.map((m) => m.toJson()), before);
        expect(host.sink.texts, isEmpty);
      },
    );
  }

  test(
    'timeout signals plugin cancellation and fails without falling through',
    () async {
      routes = InputRoutes(scope, timeout: const Duration(milliseconds: 20));
      late InputContext seen;
      register(
        'stalled',
        Router((input) {
          seen = input;
          return Completer<InputRoute?>().future;
        }),
      );
      expect(await run(), InputOutcome.failed);
      expect(seen.isCancelled, isTrue);
      expect(host.messages.join(), contains('timed out'));
    },
  );

  test(
    'a missing handler and router failure are visible, persisted errors',
    () async {
      final registered = register(
        'route',
        Router((_) async => InputRoute('missing')),
      );
      expect(await run(), InputOutcome.failed);
      expect(host.messages.join(), contains('Unknown input handler'));
      await registered.dispose();
      register(
        'throwing',
        Router((_) async => throw StateError('router broke')),
      );
      expect(await run(), InputOutcome.failed);
      expect(host.messages.join(), contains('router broke'));
      expect(history.where((m) => m.role == Role.user), hasLength(2));
    },
  );

  test(
    'removed contributions cannot consume input or publish late replies',
    () async {
      final router = register(
        'route',
        Router((_) async => InputRoute('reply')),
      );
      final started = Completer<void>();
      final release = Completer<String>();
      final handler = register(
        'reply',
        Handler((input, route) {
          started.complete();
          return release.future;
        }),
      );
      final pending = run();
      await started.future;
      await handler.dispose();
      release.complete('obsolete');
      expect(await pending, InputOutcome.failed);
      expect(host.sink.texts, isEmpty);
      await router.dispose();
      expect(await run(), InputOutcome.pass);
    },
  );
}
