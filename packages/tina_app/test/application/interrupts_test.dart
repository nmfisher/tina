import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

void main() {
  for (final accept in [true, false]) {
    test('review $accept resumes target without cancelling it', () async {
      final calls = Invocations();
      final target = calls.create(
        component: const ComponentInfo('a', 'Agent'),
        conversationId: 'c',
      );
      final source = calls.create(
        component: const ComponentInfo('b', 'Reviewer'),
        conversationId: 'c',
      );
      final decision = Completer<bool?>();
      final shown = Completer<void>();
      final output = <String>[];
      var applied = false;
      final interrupts = Interrupts(calls)
        ..presenter = (prompt) {
          expect(prompt.mode, InterruptMode.review);
          expect(target.isHeld, isTrue);
          shown.complete();
          return decision.future;
        };
      final result = source.run(
        (_) => interrupts.ask(
          source: source,
          target: target,
          title: 'Enable rule?',
          mode: InterruptMode.review,
          onAccepted: () async {
            expect(target.isHeld, isTrue);
            expect(target.isCancelled, isFalse);
            applied = true;
          },
        ),
      );
      await shown.future;
      target.output(() => output.add('queued'));
      expect(output, isEmpty);
      decision.complete(accept);
      expect(
        await result,
        accept ? InterruptResult.accepted : InterruptResult.declined,
      );
      await interrupts.ready('c');
      expect(applied, accept);
      expect(target.isCancelled, isFalse);
      expect(target.isHeld, isFalse);
      expect(output, ['queued']);
      target.cancel();
      interrupts.dispose();
    });
  }

  test(
    'cancel a review releases its hold without accepting or cancelling the target',
    () async {
      final calls = Invocations();
      final target = calls.create(
        component: const ComponentInfo('a', 'Agent'),
        conversationId: 'c',
      );
      final source = calls.create(
        component: const ComponentInfo('b', 'Reviewer'),
        conversationId: 'c',
      );
      final shown = Completer<void>();
      final interrupts = Interrupts(calls)
        ..presenter = (_) {
          shown.complete();
          return Completer<bool?>().future;
        };
      final result = interrupts.ask(
        source: source,
        target: target,
        title: 'Review',
        mode: InterruptMode.review,
      );
      await shown.future;
      interrupts.cancelAll();
      expect(await result, InterruptResult.cancelled);
      expect(target.isHeld, isFalse);
      expect(target.isCancelled, isFalse);
      target.cancel();
      source.cancel();
      interrupts.dispose();
    },
  );

  test('decline resumes output and leaves other holds intact', () async {
    final calls = Invocations();
    final target = calls.create(
      component: const ComponentInfo('a', 'Agent'),
      conversationId: 'c',
    );
    final source = calls.create(
      component: const ComponentInfo('b', 'Classifier'),
      conversationId: 'c',
    );
    final decision = Completer<bool?>();
    final shown = Completer<void>();
    final interrupts = Interrupts(calls)
      ..presenter = (_) {
        expect(target.isHeld, isTrue);
        shown.complete();
        return decision.future;
      };
    final otherHold = target.hold();
    final result = source.run(
      (_) => interrupts.ask(source: source, target: target, title: 'Switch?'),
    );
    await shown.future;
    final output = <String>[];
    target.output(() => output.add('one'));
    target.output(() => output.add('two'));
    decision.complete(false);
    expect(await result, InterruptResult.declined);
    expect(output, isEmpty);
    expect(target.isHeld, isTrue);
    await otherHold.dispose();
    expect(output, ['one', 'two']);
    target.cancel();
  });

  test(
    'accept joins target before handoff and keeps conversation queue held',
    () async {
      final calls = Invocations();
      final target = calls.create(
        component: const ComponentInfo('a', 'Agent'),
        conversationId: 'c',
      );
      final source = calls.create(
        component: const ComponentInfo('b', 'Classifier'),
        conversationId: 'c',
      );
      final began = Completer<void>();
      final cleanup = Completer<void>();
      final running = target.run((context) async {
        began.complete();
        await context.cancelSignal;
        await cleanup.future;
      });
      final stopped = expectLater(running, throwsA(isA<InvocationCancelled>()));
      await began.future;
      final interrupts = Interrupts(calls)..presenter = (_) async => true;
      final handingOff = Completer<void>();
      final finishHandoff = Completer<void>();
      final result = source.run(
        (_) => interrupts.ask(
          source: source,
          target: target,
          title: 'Switch?',
          onAccepted: () async {
            expect(target.isDone, isTrue);
            handingOff.complete();
            await finishHandoff.future;
          },
        ),
      );
      await target.cancelSignal;
      expect(handingOff.isCompleted, isFalse);
      cleanup.complete();
      await handingOff.future;
      var drained = false;
      final queue = interrupts.ready('c').then((_) => drained = true);
      await pumpEventQueue();
      expect(drained, isFalse);
      finishHandoff.complete();
      expect(await result, InterruptResult.accepted);
      await queue;
      await stopped;
      expect(source.isCancelled, isFalse);
    },
  );

  test('source removal and presenter failure release the target', () async {
    final calls = Invocations();
    final target = calls.create(
      component: const ComponentInfo('a', 'Agent'),
      conversationId: 'c',
    );
    final source = calls.create(
      component: const ComponentInfo('b', 'Classifier'),
      conversationId: 'c',
    );
    final shown = Completer<void>();
    final interrupts = Interrupts(calls)
      ..presenter = (_) {
        shown.complete();
        return Completer<bool?>().future;
      };
    final result = interrupts.ask(
      source: source,
      target: target,
      title: 'Switch?',
    );
    await shown.future;
    source.cancel('Plugin removed');
    expect(await result, InterruptResult.cancelled);
    expect(target.isHeld, isFalse);
    final second = calls.create(
      component: const ComponentInfo('b', 'Classifier'),
      conversationId: 'c',
    );
    interrupts.presenter = (_) => throw StateError('UI disposed');
    await expectLater(
      interrupts.ask(source: second, target: target, title: 'Switch?'),
      throwsStateError,
    );
    expect(target.isHeld, isFalse);
    target.cancel();
    second.cancel();
  });

  test('headless returns unavailable without holding the target', () async {
    final calls = Invocations();
    final source = calls.create(
      component: const ComponentInfo('b', 'Classifier'),
      conversationId: 'c',
    );
    final target = calls.create(
      component: const ComponentInfo('a', 'Agent'),
      conversationId: 'c',
    );
    expect(
      await Interrupts(
        calls,
      ).ask(source: source, target: target, title: 'Switch?'),
      InterruptResult.unavailable,
    );
    expect(target.isHeld, isFalse);
    calls.cancelAll();
  });
}
