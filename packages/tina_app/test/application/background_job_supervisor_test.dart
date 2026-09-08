import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_app/src/execution/background_job_supervisor.dart';

void main() {
  test('one job per kind across conversations; ownership captured', () async {
    final supervisor = BackgroundJobSupervisor();
    final gate = Completer<void>();
    final job = supervisor.start('index', 'one', (_) => gate.future)!;
    expect(supervisor.start('index', 'two', (_) async {}), isNull);
    expect(job.conversationId, 'one');
    final other = supervisor.start('environment', 'two', (_) async {})!;
    await other.done;
    gate.complete();
    await job.done;
    expect(supervisor.running('index'), isFalse);
  });
  test(
    'cancel is idempotent and retains admission until acknowledgement',
    () async {
      final supervisor = BackgroundJobSupervisor();
      final ack = Completer<void>();
      final requested = Completer<void>();
      final job = supervisor.start('index', 'one', (job) async {
        await job.cancelled;
        requested.complete();
        await ack.future;
      })!;
      job.cancel();
      job.cancel();
      await requested.future;
      expect(supervisor.running('index'), isTrue);
      ack.complete();
      await job.done;
      expect(supervisor.running('index'), isFalse);
    },
  );
  test('failure is observable and clears the guard', () async {
    final supervisor = BackgroundJobSupervisor();
    final job = supervisor.start('index', 'one', (_) async {
      throw StateError('failure');
    })!;
    await job.done;
    expect(job.error, isStateError);
    expect(supervisor.running('index'), isFalse);
  });
  test(
    'shutdown rejects late work and waits for cancellation acknowledgement',
    () async {
      final supervisor = BackgroundJobSupervisor();
      final ack = Completer<void>();
      final cancelled = Completer<void>();
      supervisor.start('environment', 'one', (job) async {
        await job.cancelled;
        cancelled.complete();
        await ack.future;
      });
      final stopped = supervisor.shutdown();
      await cancelled.future;
      expect(supervisor.start('index', 'two', (_) async {}), isNull);
      expect(supervisor.running('environment'), isTrue);
      ack.complete();
      await stopped;
    },
  );
}
