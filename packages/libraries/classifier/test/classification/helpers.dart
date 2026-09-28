import 'dart:convert';

import 'package:classifier/classification.dart';
import 'package:classifier/judgments.dart';

class MemoryStore implements ClassificationStore {
  Map<String, dynamic>? manifest;
  final records = <String, Map<String, dynamic>>{};
  @override
  Future<T> withWriter<T>(Future<T> Function() work) => work();
  @override
  Future<Map<String, dynamic>?> readManifest() async => manifest;
  @override
  Future<Map<String, dynamic>?> readRecord(String id) async => records[id];
  @override
  Future<void> writeManifest(Map<String, Object?> value) async {
    manifest = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  }

  @override
  Future<void> writeRecord(String id, Map<String, Object?> record) async {
    records[id] = jsonDecode(jsonEncode(record)) as Map<String, dynamic>;
  }
}

final numberContract = DataContract<int>(
  id: 'example.count',
  schema: {'type': 'integer'},
  encode: (v) => v,
  decode: (v) => v as int,
);
final stringContract = DataContract<String>(
  id: 'example.description',
  schema: {'type': 'string'},
  encode: (v) => v,
  decode: (v) => v as String,
);

class MemorySource<I> implements ClassificationSource<I> {
  @override
  final DataContract<I> contract;
  @override
  final Object identity;
  final Map<String, List<I>> subjects;
  int snapshots = 0;
  int checks = 0;
  InputCoverage coverage = InputCoverage();
  @override
  InputSplitter<I>? splitter;
  MemorySource(
    this.contract,
    this.subjects, {
    this.identity = 'memory-v1',
    this.splitter,
  });
  String _fingerprint(String subject) => canonicalFingerprint({
    'values': subjects[subject]?.map(contract.encode).toList(),
    'coverage': coverage.toJson(),
  });
  @override
  Future<SourceSnapshot<I>> snapshot(
    SourceRequest request,
    JudgmentCancellation cancellation,
  ) async {
    snapshots++;
    final values = subjects[request.subject] ?? <I>[];
    return SourceSnapshot(
      units: [
        for (var i = 0; i < values.length; i++)
          SourceUnit('entry:$i', values[i]),
      ],
      revision: SourceRevision({
        'subject': request.subject,
        'fingerprint': _fingerprint(request.subject),
      }),
      coverage: coverage,
      splitter: splitter,
    );
  }

  @override
  Future<bool> isCurrent(
    SourceRevision revision,
    JudgmentCancellation cancellation,
  ) async {
    checks++;
    return revision.receipt['fingerprint'] ==
        _fingerprint(revision.receipt['subject'] as String);
  }
}

class Executor implements ClassificationExecutor {
  @override
  Object configuration = 'executor-v1';
  final calls = <String>[];
  int active = 0;
  int peak = 0;
  Future<Map<String, Object?>> Function(String id, Map<String, Object?> input)?
  respond;
  int Function(Map<String, Object?> request)? count;
  @override
  int estimate<I, O>(ClassificationRequest<I, O> request) =>
      count?.call(request.toJson()) ??
      conservativeTokenEstimate(request.toJson());
  @override
  Future<ClassificationResult<O>> execute<I, O>(
    ClassificationRequest<I, O> request,
    JudgmentCancellation cancellation, {
    required int maxInputTokens,
    required int maxOutputTokens,
  }) async {
    calls.add(request.definition.id);
    active++;
    if (active > peak) peak = active;
    try {
      final input = request.input.toJson(request.definition.input);
      final raw = respond == null
          ? numberResponse(request.definition.id, input)
          : await respond!(request.definition.id, input);
      return ClassificationResult.fromJson(raw, request.definition.output);
    } finally {
      active--;
    }
  }
}

Map<String, Object?> numberResponse(String id, Map<String, Object?> input) {
  final units = (input['evidence'] as List).cast<Map>();
  var sum = 0;
  for (final unit in units) {
    final value = unit['value'];
    sum += value is int ? value : (value as Map)['value'] as int? ?? 0;
  }
  return {
    'outcome': 'classified',
    'value': id.endsWith('final') || id == 'direct' ? 'total=$sum' : sum,
    'evidence': units.map((u) => u['id'] as String).toList(),
    'explanation': 'sum of observed values',
  };
}

ClassifierDefinition<int, int> numberDefinition([
  String id = 'count',
  int revision = 1,
]) => ClassifierDefinition(
  id: id,
  revision: revision,
  agentType: 'counter',
  instructions: 'Count observations.',
  input: numberContract,
  output: numberContract,
);
ClassificationTask<int, int> numberTask(
  MemorySource<int> source, {
  String key = 'entity',
  String? subject,
  String id = 'count',
  int revision = 1,
}) => ClassificationTask(
  key: key,
  request: SourceRequest(subject ?? key),
  source: source,
  plan: SingleRequestPlan(numberDefinition(id, revision)),
);
ClassificationBudget smallBudget(int input) => ClassificationBudget(
  contextTokens: input + 30,
  outputTokens: 20,
  safetyTokens: 10,
  maxInputTokens: input,
);
