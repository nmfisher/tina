import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:tina_engine/src/terminal/pty_output.dart';

Future<void> turn() => Future<void>.delayed(Duration.zero);

void main() {
  test('paused subscriptions hold credits until actual delivery', () async {
    var credit = 0;
    final output = PtyOutput(onConsumed: (n) => credit += n);
    final seen = <int>[];
    final sub = output.stream.listen(seen.addAll)..pause();
    output.add(Uint8List.fromList([1, 2]));
    output.add(Uint8List.fromList([3]));
    await turn();
    expect(credit, 0);
    expect(output.pendingBytes, 3);
    expect(seen, isEmpty);
    sub.resume();
    await turn();
    expect(seen, [1, 2, 3]);
    expect(credit, 3);
    expect(output.pendingBytes, 0);
    output.finish();
    await sub.cancel();
  });

  test('pause from a callback stops the next chunk and survives completion',
      () async {
    var credit = 0;
    final output = PtyOutput(onConsumed: (n) => credit += n);
    final seen = <int>[];
    final done = Completer<void>();
    late StreamSubscription<Uint8List> sub;
    sub = output.stream.listen((bytes) {
      seen.addAll(bytes);
      if (seen.length == 1) sub.pause();
    }, onDone: done.complete);
    output.add(Uint8List.fromList([1]));
    output.add(Uint8List.fromList([2]));
    output.finish();
    await turn();
    expect(seen, [1]);
    expect(credit, 1);
    expect(done.isCompleted, isFalse);
    sub.resume();
    await done.future;
    expect(seen, [1, 2]);
    expect(credit, 2);
  });

  test('late consumer receives output then done after natural completion',
      () async {
    final output = PtyOutput(onConsumed: (_) {});
    output.add(Uint8List.fromList([42]));
    output.finish();
    await turn();
    expect(await output.stream.expand((bytes) => bytes).toList(), [42]);
  });

  test('cancel explicitly releases credit without growing a hidden queue',
      () async {
    var credit = 0;
    final output = PtyOutput(onConsumed: (n) => credit += n);
    final sub = output.stream.listen((_) {})..pause();
    output.add(Uint8List(10));
    await sub.cancel();
    output.add(Uint8List(20));
    expect(credit, 30);
    expect(output.pendingBytes, 0);
    output.finish();
  });
}
