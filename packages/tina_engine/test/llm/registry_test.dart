import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_provider.dart';

/// A [ProviderBuilder] that records every [ProviderInstance] it received and
/// returns a throwaway [FakeProvider]. Lets us assert what the registry handed
/// to the builder without standing up a real provider.
ProviderBuilder _recording(List<ProviderInstance> into) =>
    (ProviderInstance c) {
      into.add(c);
      return FakeProvider(const [], model: c.model);
    };

ProviderDescriptor _desc(
  String id, {
  String baseUrl = 'https://example.test',
  List<AuthSource> auth = const [
    AuthSource('TEST_KEY', AuthScheme.bearerToken),
  ],
  Map<String, ModelInfo> models = const {},
  int? requestsPerMinute,
  required ProviderBuilder builder,
}) =>
    ProviderDescriptor(
      id: id,
      name: id,
      authSources: auth,
      defaultBaseUrl: baseUrl,
      builder: builder,
      models: models,
      requestsPerMinute: requestsPerMinute,
    );

/// Send one minimal request through [p] and run it to completion — the
/// observable side of "did the launch-slot queue space these starts?".
Future<void> _drain(LlmProvider p) => p
    .send(
        system: 's',
        messages: const [Message(role: Role.user, content: [TextBlock('hi')])],
        tools: const [])
    .drain<void>();

void main() {
  group('ModelReference.parse', () {
    test('bare model name → null provider', () {
      final r = ModelReference.parse('gpt-4o');
      expect(r.providerId, isNull);
      expect(r.modelId, 'gpt-4o');
    });

    test('provider/model split', () {
      final r = ModelReference.parse('openai/gpt-4o');
      expect(r.providerId, 'openai');
      expect(r.modelId, 'gpt-4o');
    });

    test('splits on the FIRST slash only (OpenRouter-style ids)', () {
      final r = ModelReference.parse('openrouter/anthropic/claude-3.5-sonnet');
      expect(r.providerId, 'openrouter');
      expect(r.modelId, 'anthropic/claude-3.5-sonnet');
    });

    test('toString round-trips', () {
      expect(ModelReference(null, 'gpt-4o').toString(), 'gpt-4o');
      expect(ModelReference('openai', 'gpt-4o').toString(), 'openai/gpt-4o');
    });
  });

  group('ProviderRegistry registration & lookup', () {
    test('providerIds are sorted', () {
      final r = ProviderRegistry(env: {})
        ..register(_desc('grok', builder: _recording([])))
        ..register(_desc('anthropic', builder: _recording([])))
        ..register(_desc('deepseek', builder: _recording([])));
      expect(r.providerIds, ['anthropic', 'deepseek', 'grok']);
    });

    test('descriptor() returns null for unknown provider', () {
      final r = ProviderRegistry(env: {});
      expect(r.descriptor('nope'), isNull);
    });

    test('modelsFor lists a provider catalog, empty for unknown', () {
      final r = ProviderRegistry(env: {})
        ..register(_desc('openai',
            builder: _recording([]),
            models: {
              'gpt-4o': const ModelInfo(
                  id: 'gpt-4o', name: 'GPT-4o', contextWindow: 128000, maxOutput: 16384),
            }));
      expect(r.modelsFor('openai').single.id, 'gpt-4o');
      expect(r.modelsFor('nope'), isEmpty);
    });
  });

  group('findModel', () {
    test('prefixed lookup hits the named provider', () {
      final r = ProviderRegistry(env: {})
        ..register(_desc('openai',
            builder: _recording([]),
            models: {'gpt-4o': const ModelInfo(id: 'gpt-4o', name: '', contextWindow: 1, maxOutput: 1)}));
      expect(r.findModel('openai/gpt-4o')?.id, 'gpt-4o');
      expect(r.findModel('openai/missing'), isNull);
    });

    test('bare unique model resolves; ambiguous and missing return null', () {
      final r = ProviderRegistry(env: {})
        ..register(_desc('a',
            builder: _recording([]),
            models: {'shared': const ModelInfo(id: 'shared', name: '', contextWindow: 1, maxOutput: 1)}))
        ..register(_desc('b',
            builder: _recording([]),
            models: {'shared': const ModelInfo(id: 'shared', name: '', contextWindow: 1, maxOutput: 1)}));
      expect(r.findModel('shared'), isNull); // ambiguous
      expect(r.findModel('nope'), isNull); // missing
    });
  });

  group('resolve', () {
    test('prefixed known provider trusts the prefix (model need not catalog)', () {
      final r = ProviderRegistry(env: {})
        ..register(_desc('openai', builder: _recording([])));
      final resolved = r.resolve('openai/any-model-id');
      expect(resolved.descriptor.id, 'openai');
      expect(resolved.modelId, 'any-model-id');
    });

    test('unknown provider throws with the known list', () {
      final r = ProviderRegistry(env: {})
        ..register(_desc('anthropic', builder: _recording([])));
      expect(
        () => r.resolve('nope/x'),
        throwsA(isA<ProviderRegistryException>()
            .having((e) => e.message, 'message', contains('Unknown provider'))),
      );
    });

    test('bare unique model resolves; ambiguous and missing throw', () {
      final r = ProviderRegistry(env: {})
        ..register(_desc('a',
            builder: _recording([]),
            models: {'m': const ModelInfo(id: 'm', name: '', contextWindow: 1, maxOutput: 1)}));
      expect(r.resolve('m').descriptor.id, 'a');

      final r2 = ProviderRegistry(env: {})
        ..register(_desc('a',
            builder: _recording([]),
            models: {'m': const ModelInfo(id: 'm', name: '', contextWindow: 1, maxOutput: 1)}))
        ..register(_desc('b',
            builder: _recording([]),
            models: {'m': const ModelInfo(id: 'm', name: '', contextWindow: 1, maxOutput: 1)}));
      expect(() => r2.resolve('m'), throwsA(isA<ProviderRegistryException>()));

      final r3 = ProviderRegistry(env: {});
      expect(() => r3.resolve('m'), throwsA(isA<ProviderRegistryException>()));
    });
  });

  group('build', () {
    test('apiKeyOverride wins and is passed to the builder', () {
      final captured = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'from-env'})
        ..register(_desc('p',
            baseUrl: 'https://default.test',
            builder: _recording(captured)));
      r.build('p/model', apiKeyOverride: 'explicit');
      expect(captured.single.apiKey, 'explicit');
      expect(captured.single.baseUrl, 'https://default.test');
      expect(captured.single.model, 'model');
    });

    test('env-resolved key uses the first authSource whose env var is set', () {
      final captured = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'FALLBACK': 'fb'})
        ..register(_desc('p',
            auth: const [
              AuthSource('PRIMARY', AuthScheme.bearerToken),
              AuthSource('FALLBACK', AuthScheme.apiKeyHeader),
            ],
            builder: _recording(captured)));
      r.build('p/model');
      expect(captured.single.apiKey, 'fb');
    });

    test('priority: when both env vars are set, the first source wins', () {
      final captured = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'PRIMARY': 'pri', 'FALLBACK': 'fb'})
        ..register(_desc('p',
            auth: const [
              AuthSource('PRIMARY', AuthScheme.bearerToken),
              AuthSource('FALLBACK', AuthScheme.apiKeyHeader),
            ],
            builder: _recording(captured)));
      r.build('p/model');
      expect(captured.single.apiKey, 'pri');
    });

    test('a missing key no longer throws — build returns a provider with an empty key', () {
      // The first-run setup path boots before any key is configured, so build
      // tolerates an empty key (providers don't validate it). A missing key
      // surfaces later, as a send-time auth error, if a turn is attempted.
      final captured = <ProviderInstance>[];
      final r = ProviderRegistry(env: {})
        ..register(_desc('p',
            auth: const [AuthSource('NEEDED', AuthScheme.bearerToken)],
            builder: _recording(captured)));
      final provider = r.build('p/model');
      expect(provider, isNotNull);
      expect(captured.single.apiKey, '');
    });

    test('a none-auth (local) provider builds without a key', () {
      final captured = <ProviderInstance>[];
      final r = ProviderRegistry(env: {})
        ..register(_desc('ollama',
            baseUrl: 'http://localhost:11434/v1',
            auth: const [AuthSource('', AuthScheme.none)],
            builder: _recording(captured)));
      r.build('ollama/llama3');
      expect(captured.single.apiKey, '');
      expect(captured.single.baseUrl, 'http://localhost:11434/v1');
    });

    test('overrides for baseUrl/maxTokens/streamIdleTimeout pass through', () {
      final captured = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc('p', builder: _recording(captured)));
      r.build('p/model',
          baseUrlOverride: 'https://override.test',
          maxTokens: 1234,
          streamIdleTimeout: const Duration(seconds: 7));
      final c = captured.single;
      expect(c.baseUrl, 'https://override.test');
      expect(c.maxTokens, 1234);
      expect(c.streamIdleTimeout, const Duration(seconds: 7));
    });

    test('defaults apply when no overrides are given', () {
      final captured = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc('p', builder: _recording(captured)));
      r.build('p/model');
      expect(captured.single.maxTokens, ProviderRegistry.defaultMaxTokens);
      expect(captured.single.streamIdleTimeout, const Duration(seconds: 60));
    });

    test("forwards the model's extraBody to the builder", () {
      final captured = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc(
          'p',
          builder: _recording(captured),
          models: {
            'm': ModelInfo(
              id: 'm',
              name: 'M',
              contextWindow: 8192,
              maxOutput: 1024,
              extraBody: {'chat_template_kwargs': {'enable_thinking': true}},
            ),
          },
        ));
      r.build('p/m');
      expect(captured.single.extraBody,
          {'chat_template_kwargs': {'enable_thinking': true}});
    });

    test('extraBody is empty when the model declares none', () {
      final captured = <ProviderInstance>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc(
          'p',
          builder: _recording(captured),
          models: {
            'm': ModelInfo(
                id: 'm', name: 'M', contextWindow: 8192, maxOutput: 1024),
          },
        ));
      r.build('p/m');
      expect(captured.single.extraBody, isEmpty);
    });
  });

  group('decorator', () {
    test('wraps the built provider when set (sees the inner provider)', () {
      final built = FakeProvider(const [], model: 'model');
      final wrapped = FakeProvider(const [], model: 'wrapped');
      final r = ProviderRegistry(env: {})
        ..register(_desc('p', builder: (_) => built));
      r.decorator = (inner) {
        expect(identical(inner, built), isTrue,
            reason: 'decorator receives the builder result');
        return wrapped;
      };
      expect(identical(r.build('p/model'), wrapped), isTrue);
    });

    test('null (default) returns the builder result unwrapped', () {
      final built = FakeProvider(const [], model: 'model');
      final r = ProviderRegistry(env: {})
        ..register(_desc('p', builder: (_) => built));
      expect(r.decorator, isNull);
      expect(identical(r.build('p/model'), built), isTrue);
    });
  });

  group('buildPooled', () {
    test('members get their own launch slots with distinct queue keys', () {
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc('a',
            baseUrl: 'https://a.test', builder: _recording([])))
        ..register(_desc('b',
            baseUrl: 'https://b.test', builder: _recording([])));
      r.rateLimiter.minInterval = const Duration(milliseconds: 10);

      final pool = r.buildPooled(['a/m', 'b/m']) as PooledProvider;

      expect(pool.members, hasLength(2));
      final keys = [
        for (final m in pool.members)
          (m as RateLimitedProvider).limitKey
      ];
      expect(keys[0], isNot(keys[1]),
          reason: 'distinct endpoints space against THEMSELVES, not each '
              'other — the whole premise of pooling');
      expect(pool.members.every((m) => m is! RetryingProvider), isTrue,
          reason: 'retry policy belongs to the pool as a whole');
    });

    test('build() over a pool descriptor applies the policy stack exactly once', () {
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(
            _desc('a', baseUrl: 'https://a.test', builder: _recording([])));
      r.rateLimiter.minInterval = const Duration(milliseconds: 10);
      r.maxSendRetries = 2;
      r.registerPool(
          _desc('pool', builder: (c) => r.buildPooled(['a/${c.model}'])));

      final built = r.build('pool/m');

      // retry outermost → peel it, and what's left must be the bare pool:
      // a RateLimitedProvider here would mean the degenerate queue key got
      // applied, serializing the whole pool through one slot.
      final beneathRetry = built is RetryingProvider ? built.inner : built;
      expect(beneathRetry, isA<PooledProvider>());
      expect(beneathRetry is RateLimitedProvider, isFalse);
    });

    test('a pool over a pool throws', () {
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc('a', builder: _recording([])));
      r.registerPool(_desc('p', builder: (c) => r.buildPooled(['a/${c.model}'])));

      expect(() => r.buildPooled(['p/m']),
          throwsA(isA<ProviderRegistryException>().having(
              (e) => e.message, 'message', contains('nested pool'))));
    });

    test('an empty member list throws', () {
      final r = ProviderRegistry(env: {});
      expect(() => r.buildPooled(const []),
          throwsA(isA<ProviderRegistryException>()));
    });
  });

  group('setRequestRate (per-provider RPM)', () {
    test('rpm < 0 throws', () {
      final r = ProviderRegistry(env: {});
      expect(
          () => r.setRequestRate('nim', -1), throwsA(isA<ArgumentError>()));
    });

    test('a descriptor hint alone spaces the queue (global limiter off)',
        () async {
      // 600 rpm → 100 ms between starts. The registry-wide limiter is fully
      // disabled, so the ONLY thing that can space these sends is the
      // descriptor's own hint — this is the case where the hint must engage
      // the launch-slot wrapper on its own.
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc('p',
            builder: _recording([]), requestsPerMinute: 600));

      final provider = r.build('p/m');
      expect(provider, isA<RateLimitedProvider>(),
          reason: 'the hint must engage the launch-slot queue even when the '
              'registry-wide default is disabled');
      final key = (provider as RateLimitedProvider).limitKey;
      expect(key, providerQueueKey('https://example.test', 'k'),
          reason: 'the queue is keyed by endpoint+API key, not descriptor id');
      expect(r.rateLimiter.minIntervalFor(key),
          const Duration(milliseconds: 100),
          reason: '60 s / 600 rpm, rounded up to whole ms');

      final watch = Stopwatch()..start();
      await Future.wait([_drain(provider), _drain(provider)]);
      expect(watch.elapsedMilliseconds, greaterThan(80),
          reason: 'the second send cannot start until the first has held its '
              '100 ms launch slot');
    });

    test('rpm = 0 explicitly disables spacing for that provider', () async {
      // Hint says 100 ms, the global default says 100 ms — the user's 0 must
      // beat both: two sends on the key launch together.
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc('p',
            builder: _recording([]), requestsPerMinute: 600));
      r.setRequestRate('p', 0);
      r.rateLimiter.minInterval = const Duration(milliseconds: 100);

      final provider = r.build('p/m');
      final key = provider is RateLimitedProvider
          ? provider.limitKey
          : providerQueueKey('https://example.test', 'k');
      expect(r.rateLimiter.minIntervalFor(key), Duration.zero,
          reason: '0 installs Duration.zero (explicit disable), not a '
              'fall-through to the 100 ms global');

      final watch = Stopwatch()..start();
      await Future.wait([_drain(provider), _drain(provider)]);
      expect(watch.elapsedMilliseconds, lessThan(80),
          reason: 'either spacing left on (100 ms) would force ≥ 100 ms');
    });

    test('the user override beats the descriptor hint', () async {
      // Hint: 600 rpm → 100 ms. Override: 6000 rpm → 10 ms. The override
      // wins, or these two sends would be a full 100 ms apart.
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(_desc('p',
            builder: _recording([]), requestsPerMinute: 600));
      r.setRequestRate('p', 6000);

      final provider = r.build('p/m');
      final key = (provider as RateLimitedProvider).limitKey;
      expect(r.rateLimiter.minIntervalFor(key),
          const Duration(milliseconds: 10));

      final watch = Stopwatch()..start();
      await Future.wait([_drain(provider), _drain(provider)]);
      expect(watch.elapsedMilliseconds, lessThan(80),
          reason: 'the hint\'s 100 ms spacing would force ≥ 100 ms');
    });
  });
}
