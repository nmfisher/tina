import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';
import '../helpers/agent_test_fixtures.dart';
import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_provider.dart';

class _Client extends http.BaseClient {
  final String body;
  int calls = 0;
  _Client(this.body);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    return http.StreamedResponse(Stream.value(utf8.encode(body)), 429,
        headers: {'retry-after': '0'});
  }
}

class _Limiter extends ProviderRateLimiter {
  int deferrals = 0;
  _Limiter() : super(minInterval: const Duration(milliseconds: 1));
  @override
  void defer(String providerId) {
    deferrals++;
  }
}

String _body(Object code, {bool usage = false}) => jsonEncode({
      'error': {
        'code': code,
        'type': 'account_error',
        'message': '余额不足或无可用资源包,请充值。'
      },
      if (usage) 'usage': {'prompt_tokens': 7, 'completion_tokens': 2},
    });

void main() {
  for (final code in ['1113', '1302']) {
    test('rate limiter only penalizes transient 429 ($code)', () async {
      final limiter = _Limiter();
      final provider = RateLimitedProvider(
          FakeProvider([
            [httpStreamError('GLM', 429, _body(code))],
          ]),
          limiter,
          'key');
      await provider.send(system: 'sys', messages: [], tools: []).toList();
      expect(limiter.deferrals, code == '1113' ? 0 : 1);
    });
  }
  for (final code in [
    1113,
    '1113',
    '1308',
    '1309',
    '1310',
    '1311',
    '1313',
    '1314',
    '1315',
    '1316',
    '1317',
    '1318',
    '1319',
    '1320',
    '1321'
  ]) {
    test('GLM account code $code stops retries and preserves metadata', () {
      final error = httpStreamError('GLM', 429, _body(code));
      expect(error.providerCode, '$code');
      expect(error.providerType, 'account_error');
      expect(error.requiresUserAction, isTrue);
      expect(isTransportRetryable(error), isFalse);
      expect(error.error.toString(), contains('Action required:'));
      expect(error.error.toString(), contains('provider code: $code'));
    });
  }
  test('terminal marker overrides transient and 429 status', () {
    expect(
        isTransportRetryable(const StreamError('billing',
            statusCode: 429, transient: true, requiresUserAction: true)),
        isFalse);
  });
  test('classification is provider scoped and narrow for missing codes', () {
    expect(httpStreamError('Other', 429, _body('1113')).requiresUserAction,
        isFalse);
    expect(
        httpStreamError('GLM', 500, _body('1113')).requiresUserAction, isFalse);
    expect(
        httpStreamError('GLM', 429, '{"error":{"message":"余额不足或无可用资源包,请充值。"}}')
            .requiresUserAction,
        isTrue);
    for (final body in [
      'not JSON',
      '{"error":"busy"}',
      '[]',
      '{"error":{"message":"quota temporarily busy"}}'
    ]) {
      expect(isTransportRetryable(httpStreamError('GLM', 429, body)), isTrue);
    }
  });
  for (final pooled in [false, true]) {
    for (final measured in [false, true]) {
      test('real GLM 429 stops all ladders (pool $pooled, usage $measured)',
          () async {
        final client = _Client(_body('1113', usage: measured));
        final adapter = OpenAiCompatibleAdapter(
            apiKey: '', model: 'glm', label: 'GLM', client: client);
        final spare = FakeProvider([]);
        final ledger = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
        final notices = <String>[];
        ledger.onRetriedSpendNotice = notices.add;
        final provider = RetryingProvider(MeteringProvider(
            pooled
                ? PooledProvider([adapter, spare], cooldown: Duration.zero)
                : adapter,
            ledger));
        addTearDown(provider.close);
        final sink = FakeAgentSink();
        final agent = Agent(
            provider: provider,
            tools: ToolRegistry([]),
            sink: sink,
            system: 'sys',
            policy: PermissionPolicy(),
            transportRetryAttempts: 3,
            asker: (_) async => PermissionResponse.denyOnce);
        final history = <Message>[];
        await agent.run(history: history, userInput: 'hi');
        expect(client.calls, 1);
        expect(spare.calls, isEmpty);
        expect(agent.abortedKind, AbortedKind.providerTerminal);
        expect(agent.abortedReason, contains('Action required:'));
        expect(history.where((m) => m.role == Role.assistant), isEmpty);
        expect(ledger.totalEstimatedTokens, 0);
        expect(ledger.totalTokens, measured ? 9 : 0);
        expect(notices, isEmpty);
        expect(
            sink.notices.any((n) => n.message.contains('retry 1/')), isFalse);
      });
    }
  }
  test('scheduler does not treat account failure as transient', () async {
    final registry = scriptedRegistry({
      'a': [httpStreamError('GLM', 429, _body('1113'))],
    });
    final scheduler = testScheduler(registry, pipeline: defaultTestPipeline);
    addTearDown(scheduler.dispose);
    final result = await scheduler.runStandalone(
        systemPrompt: 'sys',
        task: 'hi',
        parentReference: 'a/a-model',
        sink: FakeAgentSink(),
        includeDelegate: false);
    expect(result.isError, isTrue);
    expect(result.transient, isFalse);
  });
  for (final code in ['1302', '1305', 'unknown']) {
    test('ordinary 429 $code still retries without fabricated spend', () async {
      final client = _Client(_body(code));
      final ledger = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
      final provider = RetryingProvider(
          MeteringProvider(
              OpenAiCompatibleAdapter(
                  apiKey: '', model: 'glm', label: 'GLM', client: client),
              ledger),
          maxRetries: 1);
      addTearDown(provider.close);
      final events =
          await provider.send(system: 'sys', messages: [], tools: []).toList();
      expect(client.calls, 2);
      expect(events.whereType<StreamNotice>(), hasLength(1));
      expect(
          events.whereType<StreamError>().single.requiresUserAction, isFalse);
      expect(ledger.totalEstimatedTokens, 0);
      expect(ledger.totalTokens, 0);
    });
  }
}
