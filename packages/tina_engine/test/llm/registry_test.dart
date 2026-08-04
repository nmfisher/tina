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
  required ProviderBuilder builder,
}) =>
    ProviderDescriptor(
      id: id,
      name: id,
      authSources: auth,
      defaultBaseUrl: baseUrl,
      builder: builder,
      models: models,
    );

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
}
