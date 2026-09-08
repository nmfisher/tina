import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_app/src/execution/project_execution.dart';
import 'package:tina_app/src/environment/environment_index.dart';
import 'package:tina_app/src/environment/environment_repository.dart';
import 'package:tina_engine/tina_engine.dart';
import '../helpers/fake_host_interface.dart';

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

  @override
  List<String> surveyFolders() => ['lib'];
}

class FakeEnvironmentRunner implements EnvironmentAgentRunner {
  Future<bool> Function(EnvironmentSnapshot, RunInteraction, String?)? run;
  @override
  Future<EnvironmentExecutionResult> execute(
    EnvironmentSnapshot before,
    RunInteraction interaction, {
    String? modelRef,
  }) async => EnvironmentExecutionResult(
    await run?.call(before, interaction, modelRef) ?? true,
    SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0)
      ..record(const TokenUsage(inputTokens: 10, outputTokens: 5)),
  );
}

void main() {
  late MemoryEnvironment repository;
  late FakeEnvironmentRunner runner;
  late SpendLedger spend;
  late EnvironmentIndex service;
  setUp(() {
    repository = MemoryEnvironment();
    runner = FakeEnvironmentRunner();
    spend = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
    service = EnvironmentIndex(
      repository: repository,
      runner: runner,
      spendLedger: spend,
    );
  });
  test('absent record remains stale after a prose-only success', () async {
    expect(await service.refresh(), isFalse);
    expect(repository.recorded, 0);
    expect(spend.totalTokens, 15);
  });
  test('first load records only actual creation', () async {
    runner.run = (before, _, __) async {
      expect(before.recordPresent, isFalse);
      repository.bytes = [1];
      return true;
    };
    expect(await service.refresh(), isTrue);
    expect(repository.recorded, 1);
  });
  test('unchanged record remains stale on verification', () async {
    repository.bytes = [1];
    expect(await service.refresh(), isFalse);
    expect(repository.recorded, 0);
  });
  test(
    'changed record advances tracking using an immutable baseline',
    () async {
      repository.bytes = [1];
      runner.run = (before, _, __) async {
        repository.bytes![0] = 2;
        expect(before.recordBytes, [1]);
        return true;
      };
      expect(await service.refresh(), isTrue);
      expect(repository.recorded, 1);
    },
  );
  test('vanished record cannot prove progress', () async {
    repository.bytes = [1];
    runner.run = (_, __, ___) async {
      repository.bytes = null;
      return true;
    };
    expect(await service.refresh(), isFalse);
  });
  test(
    'cancelled/no-answer execution never records even after writing',
    () async {
      runner.run = (_, __, ___) async {
        repository.bytes = [1];
        return false;
      };
      expect(await service.refresh(), isFalse);
      expect(repository.recorded, 0);
      expect(spend.totalTokens, 15);
    },
  );
  test(
    'thrown execution leaves tracking and session spend unchanged',
    () async {
      runner.run = (_, __, ___) async {
        throw StateError('execution');
      };
      await expectLater(service.refresh(), throwsStateError);
      expect(repository.recorded, 0);
      expect(spend.totalTokens, 0);
    },
  );
  test(
    'model, attention asker, scout sink and cancellation are passed explicitly',
    () async {
      final host = FakeHostInterface();
      final cancel = Completer<void>();
      Future<PermissionResponse> asker(PermissionPrompt request) async =>
          PermissionResponse.allowOnce;
      AgentSink sink(String dir) => host;
      runner.run = (_, interaction, model) async {
        expect(model, 'chosen/model');
        expect(interaction.host, same(host));
        expect(interaction.asker, same(asker));
        expect(interaction.scoutSinkFactory, same(sink));
        expect(interaction.cancelSignal, same(cancel.future));
        return false;
      };
      await service.refresh(
        modelRef: 'chosen/model',
        host: host,
        cancelSignal: cancel.future,
        asker: asker,
        scoutSinkFactory: sink,
      );
    },
  );
  test(
    'tracking failure surfaces after environment usage has merged',
    () async {
      repository.failRecord = true;
      runner.run = (_, __, ___) async {
        repository.bytes = [1];
        return true;
      };
      await expectLater(service.refresh(), throwsStateError);
      expect(repository.recorded, 0);
      expect(spend.totalTokens, 15);
    },
  );
  test('inspection needs no runner or record-byte capture', () {
    final inspection = EnvironmentInspection(repository: repository);
    expect(inspection.status().recordPresent, isFalse);
    expect(repository.captures, [false]);
  });
}
