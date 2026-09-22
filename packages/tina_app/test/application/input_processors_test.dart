import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';
import '../helpers/fake_host_interface.dart';

class Processor implements InputProcessor {
  final FutureOr<InputDecision> Function(InputContext) callback;
  Processor(this.callback);
  @override
  FutureOr<InputDecision> process(InputContext input) => callback(input);
}

void main() {
  late PluginScope scope;
  late InputRoutes routes;
  late Completer<void> cancel;
  Registration add(String id, Object value) =>
      scope.registerContribution(pluginId: 'test', id: id, contribution: value);
  Future<PreparedInput> prepare() => routes.prepare(
    text: 'original',
    conversationId: 'conversation',
    history: [],
    cancelSignal: cancel.future,
  );
  setUp(() {
    scope = PluginScope('test');
    routes = InputRoutes(scope);
    cancel = Completer<void>();
  });
  tearDown(() => scope.dispose());

  test(
    'sync and async processors compose text and immutable metadata',
    () async {
      final labels = ['git'];
      add(
        'replace',
        Processor(
          (input) =>
              InputDecision.replace('replacement', data: {'labels': labels}),
        ),
      );
      add(
        'inspect',
        Processor((input) async {
          expect(input.originalText, 'original');
          expect(input.text, 'replacement');
          expect(input.data['labels'], ['git']);
          expect(
            () => (input.data['labels'] as List).clear(),
            throwsUnsupportedError,
          );
          labels.add('later');
          return const InputDecision.pass(data: {'checked': true});
        }),
      );
      final result = await prepare();
      expect(result.outcome, InputOutcome.pass);
      expect(result.text, 'replacement');
      expect(result.context.data, {
        'labels': ['git'],
        'checked': true,
      });
    },
  );

  test(
    'stop terminates the pipeline; empty replacement fails explicitly',
    () async {
      final first = add('stop', Processor((_) => const InputDecision.stop()));
      var calls = 0;
      add(
        'next',
        Processor((_) {
          calls++;
          return const InputDecision.replace(' ');
        }),
      );
      expect((await prepare()).outcome, InputOutcome.handled);
      expect(calls, 0);
      await first.dispose();
      final failed = await prepare();
      expect(failed.outcome, InputOutcome.failed);
      expect(failed.error.toString(), contains('use stop'));
    },
  );

  test(
    'stop also consumes headless input without recording an unmatched user message',
    () async {
      add('stop', Processor((_) => const InputDecision.stop()));
      final host = FakeHostInterface();
      addTearDown(host.dispose);
      final history = <Message>[];
      final outcome = await routes.run(
        text: 'consume',
        conversationId: 'conversation',
        history: history,
        host: host,
        cancelSignal: cancel.future,
      );
      expect(outcome, InputOutcome.handled);
      expect(history, isEmpty);
    },
  );

  for (final remove in [false, true]) {
    test(
      '${remove ? 'removal' : 'cancellation'} releases a stalled processor without late changes',
      () async {
        final started = Completer<InputContext>();
        final release = Completer<InputDecision>();
        final registration = add(
          'stall',
          Processor((input) {
            started.complete(input);
            return release.future;
          }),
        );
        final pending = prepare();
        final input = await started.future;
        if (remove) {
          await registration.dispose();
        } else {
          cancel.complete();
        }
        final result = await pending.timeout(const Duration(seconds: 1));
        expect(
          result.outcome,
          remove ? InputOutcome.failed : InputOutcome.cancelled,
        );
        expect(input.isCancelled, isTrue);
        release.complete(const InputDecision.replace('too late'));
        await Future<void>.delayed(Duration.zero);
        expect(result.text, 'original');
      },
    );
  }

  test(
    'removing an earlier processor also cancels the pending chain',
    () async {
      final first = add('first', Processor((_) => const InputDecision.pass()));
      final entered = Completer<void>();
      add(
        'stall',
        Processor((_) {
          entered.complete();
          return Completer<InputDecision>().future;
        }),
      );
      final pending = prepare();
      await entered.future;
      await first.dispose();
      expect(
        (await pending.timeout(const Duration(seconds: 1))).outcome,
        InputOutcome.failed,
      );
    },
  );
}
