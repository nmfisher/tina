import 'dart:async';

import 'package:tina/tui/attention_queue.dart';
import 'package:test/test.dart';

void main() {
  group('AttentionQueue', () {
    test('runs modals one at a time, in FIFO order', () async {
      final q = AttentionQueue();
      final order = <String>[];

      // None of these futures is awaited yet — they all enqueue at once.
      final f1 = q.run(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        order.add('one');
        return 1;
      }, onCancel: () => 0);
      final f2 = q.run(() async {
        order.add('two');
        return 2;
      }, onCancel: () => 0);
      final f3 = q.run(() async {
        order.add('three');
        return 3;
      }, onCancel: () => 0);

      // 'one' holds the keyboard (its delay hasn't elapsed).
      expect(order, isEmpty);
      expect(q.active, isTrue);
      expect(await Future.wait([f1, f2, f3]), [1, 2, 3]);
      expect(order, ['one', 'two', 'three']);
      expect(q.active, isFalse);
    });

    test('onQueued fires only for asks queued behind an open modal', () async {
      final q = AttentionQueue();
      var queued = 0;
      final gate = Completer<void>();

      final f1 = q.run<int?>(
        () async {
          await gate.future;
          return 1;
        },
        onCancel: () => null,
        onQueued: () => queued++,
      );
      expect(queued, 0); // first modal isn't "queued" — it opens
      final f2 = q.run(
        () async => 2,
        onCancel: () => 0,
        onQueued: () => queued++,
      );
      expect(queued, 1); // second one is waiting
      gate.complete();
      expect(await f1, 1);
      expect(await f2, 2);
      expect(queued, 1);
    });

    test('cancelAll drops waiting dialogs but allows new requests', () async {
      final queue = AttentionQueue();
      final gate = Completer<int>();
      final first = queue.run(() => gate.future, onCancel: () => -1);
      await pumpEventQueue();
      final queued = queue.run(
        () async => fail('cancelled dialog opened'),
        onCancel: () => -1,
      );
      queue.cancelAll();
      gate.complete(-1);
      expect(await first, -1);
      expect(await queued, -1);
      expect(await queue.run(() async => 42, onCancel: () => -1), 42);
      expect(queue.active, isFalse);
    });

    test('a throwing modal fails its caller but not the chain', () async {
      final q = AttentionQueue();
      final ran = <String>[];

      final f1 = q.run<int>(
        () async => throw StateError('boom'),
        onCancel: () => 0,
      );
      final f2 = q.run(() async {
        ran.add('after');
        return 'ok';
      }, onCancel: () => 'cancelled');

      await expectLater(f1, throwsStateError);
      expect(await f2, 'ok');
      expect(ran, ['after']);
      expect(q.active, isFalse);
    });
  });
}
