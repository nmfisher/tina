import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';

void main() {
  late IndexProgressStatus status;

  setUp(() {
    status = IndexProgressStatus();
  });

  test(
    'reads null while idle and an IndexProgress snapshot while running',
    () async {
      expect(status.read('c1'), isNull);
      status.begin();
      expect(status.read('c1'), isNotNull);
      final value = status.read('c1')! as IndexProgress;
      expect(value.done, 0);
      expect(value.total, 0);
      status.end();
      expect(status.read('c1'), isNull);
    },
  );

  test('progress updates the snapshot and fires changes', () async {
    final events = <void>[];
    final sub = status.changes.listen(events.add);
    status.begin();
    status.progress(3, 12);
    status.progress(7, 12);
    await Future<void>.delayed(Duration.zero);
    final value = status.read('c1')! as IndexProgress;
    expect(value.done, 7);
    expect(value.total, 12);
    expect(events, hasLength(3)); // begin + two progress updates
    await sub.cancel();
  });

  test(
    'end clears the counts; a late callback cannot resurrect the run',
    () async {
      status.begin();
      status.progress(2, 5);
      status.end();
      status.progress(3, 5);
      expect(status.running, isFalse);
      expect(status.read('c1'), isNull);
    },
  );

  test(
    'overlapping runs keep the indicator up until the last one ends',
    () async {
      status.begin();
      status.progress(1, 3);
      status.begin(); // a second overlapping run
      status.end(); // first run finishes
      expect(status.running, isTrue);
      expect(status.read('c1'), isNotNull);
      status.end();
      expect(status.running, isFalse);
      expect(status.read('c1'), isNull);
    },
  );
}
