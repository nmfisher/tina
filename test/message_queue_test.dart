import 'package:tina/message_queue.dart';
import 'package:test/test.dart';

void main() {
  test('enqueue and dequeue in FIFO order', () {
    final q = MessageQueue();
    q.enqueue('first');
    q.enqueue('second');
    q.enqueue('third');
    expect(q.dequeue(), 'first');
    expect(q.dequeue(), 'second');
    expect(q.dequeue(), 'third');
    expect(q.dequeue(), isNull);
  });

  test('dequeue returns null when empty', () {
    final q = MessageQueue();
    expect(q.dequeue(), isNull);
    expect(q.isEmpty, isTrue);
    expect(q.isNotEmpty, isFalse);
  });

  test('length tracks queue size', () {
    final q = MessageQueue();
    expect(q.length, 0);
    q.enqueue('a');
    expect(q.length, 1);
    q.enqueue('b');
    expect(q.length, 2);
    q.dequeue();
    expect(q.length, 1);
  });

  test('enqueue trims whitespace', () {
    final q = MessageQueue();
    q.enqueue('  hello  ');
    expect(q.dequeue(), 'hello');
  });

  test('enqueue skips empty and whitespace-only input', () {
    final q = MessageQueue();
    q.enqueue('');
    q.enqueue('   ');
    q.enqueue('\t\n');
    expect(q.length, 0);
    expect(q.isEmpty, isTrue);
  });

  test('clear empties the queue', () {
    final q = MessageQueue();
    q.enqueue('a');
    q.enqueue('b');
    q.clear();
    expect(q.isEmpty, isTrue);
    expect(q.length, 0);
    expect(q.dequeue(), isNull);
  });
}
