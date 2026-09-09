import 'package:test/test.dart';
import 'package:tina_app/src/environment/environment_index.dart';
import 'package:tina_app/src/environment/environment_repository.dart';

class MemoryEnvironment implements EnvironmentRepository {
  List<int>? bytes;
  int recorded = 0;
  bool failRecord = false;
  final captures = <bool>[];
  @override
  EnvironmentSnapshot inspect({bool captureRecord = false}) {
    captures.add(captureRecord);
    return EnvironmentSnapshot(
      recordPresent: bytes != null,
      recordBytes: captureRecord ? bytes : null,
      staleReason: recorded == 0 ? 'not verified' : null,
    );
  }

  @override
  bool advanced(EnvironmentSnapshot before) =>
      bytes != null &&
      (!before.recordPresent ||
          bytes.toString() != before.recordBytes.toString());
  @override
  void record() {
    if (failRecord) throw StateError('tracking');
    recorded++;
  }
}

void main() {
  late MemoryEnvironment repository;
  late EnvironmentIndex service;
  setUp(() {
    repository = MemoryEnvironment();
    service = EnvironmentIndex(repository: repository);
  });
  test('prose alone cannot verify an absent or unchanged record', () {
    final before = service.beginVerification();
    expect(service.finishVerification(before, completed: true), isFalse);
    repository.bytes = [1];
    final existing = service.beginVerification();
    expect(service.finishVerification(existing, completed: true), isFalse);
    expect(repository.recorded, 0);
  });
  test('creation and changed bytes advance tracking', () {
    final before = service.beginVerification();
    repository.bytes = [1];
    expect(service.finishVerification(before, completed: true), isTrue);
    final existing = service.beginVerification();
    repository.bytes![0] = 2;
    expect(existing.recordBytes, [1]);
    expect(service.finishVerification(existing, completed: true), isTrue);
    expect(repository.recorded, 2);
  });
  test('cancelled or failed turns never verify even after writing', () {
    final before = service.beginVerification();
    repository.bytes = [1];
    expect(service.finishVerification(before, completed: false), isFalse);
    expect(repository.recorded, 0);
  });
  test('a deleted record cannot prove progress', () {
    repository.bytes = [1];
    final before = service.beginVerification();
    repository.bytes = null;
    expect(service.finishVerification(before, completed: true), isFalse);
  });
  test('tracking errors are surfaced', () {
    final before = service.beginVerification();
    repository.bytes = [1];
    repository.failRecord = true;
    expect(
      () => service.finishVerification(before, completed: true),
      throwsStateError,
    );
  });
  test('inspection is read-only and does not capture record bytes', () {
    expect(
      EnvironmentInspection(repository: repository).status().recordPresent,
      isFalse,
    );
    expect(repository.captures, [false]);
  });
  test('the task leaves delegation decisions with the main conversation', () {
    final prompt = service.taskPrompt();
    expect(prompt, contains('No .tina/ENVIRONMENT.md exists'));
    expect(prompt, contains('how many sub-agents to spawn'));
    expect(prompt, contains('normal delegate tool'));
    expect(prompt, contains('Never invent a baseline'));
    repository.bytes = [1];
    expect(
      service.taskPrompt(),
      contains('Re-verify .tina/ENVIRONMENT.md: not verified'),
    );
  });
}
