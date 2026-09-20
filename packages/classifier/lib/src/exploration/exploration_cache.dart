import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../judgments/batch_runner.dart'
    show JudgmentBatchLimits, JudgmentBatchRunner;
import '../judgments/models.dart'
    show JudgmentRequest, JudgmentResult, NoulAnswer;
import '../judgments/service.dart' show JudgmentCancellation, JudgmentFailure;

/// Version assembled answers when exploration policy or snapshot codecs change.
/// Individual judgments are identified by their exact request instead.
const explorationCacheRevision = 1;

String evidenceHash(String text) =>
    sha256.convert(utf8.encode(text)).toString();
String explorationFingerprint(Object? value) =>
    evidenceHash(jsonEncode(_canonical(value)));
Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

/// Storage is optional and best effort. Implementations must bound record reads
/// and publish complete records atomically. Keys are SHA-256 strings, not paths.
abstract interface class ExplorationCache {
  Future<Map<String, dynamic>?> read(String key);
  Future<void> write(String key, Map<String, dynamic> record);
}

/// Invocation-scoped cache policy. No filesystem, credentials or chat state.
/// Entries remain reusable while their inputs match, regardless of age.
class ExplorationCacheSession {
  final ExplorationCache? store;
  final String endpoint;
  final bool refresh;
  final JudgmentCancellation cancellation;
  int hits = 0;
  ExplorationCacheSession({
    this.store,
    required this.endpoint,
    required this.cancellation,
    this.refresh = false,
  });

  String key(String kind, Object inputs) => explorationFingerprint({
    'endpoint': endpoint,
    'kind': kind,
    'inputs': inputs,
  });

  Future<Map<String, dynamic>?> get(String key) async {
    if (store == null || refresh || cancellation.isCancelled) return null;
    try {
      final record = await store!.read(key).timeout(const Duration(seconds: 1));
      if (record == null || cancellation.isCancelled || record['key'] != key)
        return null;
      final payload = Map<String, dynamic>.from(record['payload'] as Map);
      if (record['payload_hash'] != explorationFingerprint(payload))
        return null;
      return payload;
    } catch (_) {
      return null;
    }
  }

  Future<void> put(String key, Map<String, dynamic> payload) async {
    if (store == null) return;
    try {
      await store!
          .write(key, {
            'key': key,
            'payload_hash': explorationFingerprint(payload),
            'payload': payload,
          })
          .timeout(const Duration(seconds: 1));
    } catch (_) {
      /* Cache failures never discard usable evidence. */
    }
  }

  Future<CachedBatch> run(
    JudgmentBatchRunner runner,
    List<JudgmentRequest> requests, {
    int? tokenAllowance,
    int? requestAllowance,
  }) async {
    final items = List<CachedBatchItem?>.filled(requests.length, null);
    final misses = <JudgmentRequest>[];
    final indices = <int>[];
    final keys = <String>[];
    for (var i = 0; i < requests.length; i++) {
      final request = requests[i];
      final id = key('judgment', request.toJson(model: runner.budget.model));
      keys.add(id);
      final saved = await get(id);
      if (saved != null) {
        try {
          final result = JudgmentResult.fromJson(
            saved['result'],
            request: request,
          );
          items[i] = CachedBatchItem(result: result, cached: true);
          hits++;
          continue;
        } catch (_) {
          /* Invalid typed answers are misses. */
        }
      }
      if (cancellation.isCancelled) {
        items[i] = const CachedBatchItem(failure: JudgmentFailure.cancelled);
      } else if ((tokenAllowance ?? runner.limits.maxChargedTokens) <= 0 ||
          misses.length >= (requestAllowance ?? runner.limits.maxRequests)) {
        items[i] = const CachedBatchItem(
          failure: JudgmentFailure.budgetExceeded,
        );
      } else {
        indices.add(i);
        misses.add(request);
      }
    }
    var charged = 0;
    if (misses.isNotEmpty) {
      final limits = runner.limits;
      final batch = await JudgmentBatchRunner(
        service: runner.service,
        budget: runner.budget,
        limits: JudgmentBatchLimits(
          concurrency: limits.concurrency,
          maxRequests: limits.maxRequests,
          maxChargedTokens: tokenAllowance ?? limits.maxChargedTokens,
          outputTokenAllowance: limits.outputTokenAllowance,
          requestTimeout: limits.requestTimeout,
          timeout: limits.timeout,
        ),
      ).run(misses, cancellation: cancellation);
      charged = batch.chargedTokens;
      for (var j = 0; j < indices.length; j++) {
        final index = indices[j];
        final item = batch.items[j];
        items[index] = CachedBatchItem(
          result: item.result,
          failure: item.failure,
          attempted: item.attempted,
        );
        final result = item.result;
        // Exploration uses Noul judgments; don't invent codecs for other primitives.
        if (result != null &&
            result.answers.values.every((a) => a is NoulAnswer)) {
          final state = requests[index].state.value as Map;
          final instructions =
              requests[index].questions.values.first.instructions?.value;
          await put(keys[index], {
            'question':
                state['goal'] ??
                (instructions is Map ? instructions['question'] : null),
            'result': {
              'model': result.model,
              'answers': result.answers.map(
                (k, v) => MapEntry(k, {
                  'type': 'noul',
                  'noul': (v as NoulAnswer).noul,
                }),
              ),
              'usage': {
                'input_tokens': result.usage.inputTokens,
                'output_tokens': result.usage.outputTokens,
              },
            },
          });
        }
      }
    }
    return CachedBatch(items.cast<CachedBatchItem>(), charged);
  }
}

class CachedBatchItem {
  final JudgmentResult? result;
  final JudgmentFailure? failure;
  final bool attempted;
  final bool cached;
  const CachedBatchItem({
    this.result,
    this.failure,
    this.attempted = false,
    this.cached = false,
  });
}

class CachedBatch {
  final List<CachedBatchItem> items;
  final int chargedTokens;
  const CachedBatch(this.items, this.chargedTokens);
}
