import 'package:tina/config/user_config.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina/composition/config_providers.dart';
import 'package:test/test.dart';

void main() {
  group('registerConfigProviders', () {
    test('new id with wire="anthropic" registers an Anthropic-wire provider',
        () {
      final config = UserConfig(providers: {
        'zai': ProviderConfig(
          baseUrl: 'https://api.z.ai/api/anthropic',
          wire: 'anthropic',
        ),
      });
      final registry = builtinRegistry();
      registerConfigProviders(registry, config);

      final provider =
          registry.build('zai/glm-5.2', apiKeyOverride: 'test-key');
      expect(provider, isA<AnthropicProvider>());
      expect((provider as AnthropicProvider).baseUrl,
          'https://api.z.ai/api/anthropic');
      expect(provider.model, 'glm-5.2');
    });

    test('new id without wire defaults to OpenAI-compatible', () {
      final config = UserConfig(providers: {
        'ollama': ProviderConfig(baseUrl: 'http://localhost:11434/v1'),
        // no wire → defaults to 'openai'
      });
      final registry = builtinRegistry();
      registerConfigProviders(registry, config);

      final provider =
          registry.build('ollama/llama3', apiKeyOverride: '');
      expect(provider, isA<OpenAiCompatibleAdapter>());
    });

    test('new id with wire="openai" registers an OpenAI-compatible provider',
        () {
      final config = UserConfig(providers: {
        'groq': ProviderConfig(
          baseUrl: 'https://api.groq.com/openai/v1',
          wire: 'openai',
        ),
      });
      final registry = builtinRegistry();
      registerConfigProviders(registry, config);

      final provider =
          registry.build('groq/llama-3.3-70b', apiKeyOverride: 'k');
      expect(provider, isA<OpenAiCompatibleAdapter>());
    });

    test('override built-in glm with anthropic wire preserves the catalog',
        () {
      final config = UserConfig(providers: {
        'glm': ProviderConfig(
          baseUrl: 'https://api.z.ai/api/anthropic',
          wire: 'anthropic',
        ),
      });
      final registry = builtinRegistry();
      registerConfigProviders(registry, config);

      // The descriptor should now build AnthropicProvider.
      final provider =
          registry.build('glm/glm-5.2', apiKeyOverride: 'test-key');
      expect(provider, isA<AnthropicProvider>());

      // Catalog preserved — bare glm-5.2 still resolves.
      final resolved = registry.resolve('glm-5.2');
      expect(resolved.modelId, 'glm-5.2');
      expect(resolved.descriptor.id, 'glm');
    });

    test('built-in id with no wire is left unchanged', () {
      final config = UserConfig(providers: {
        'glm': ProviderConfig(baseUrl: 'https://custom.url'), // no wire
      });
      final registry = builtinRegistry();
      final beforeType = registry
          .descriptor('glm')!
          .builder(ProviderInstance(
            apiKey: '',
            model: 'glm-5.2',
            baseUrl: '',
            maxTokens: 100,
            streamIdleTimeout: const Duration(seconds: 30),
            requestTimeout: const Duration(seconds: 30),
            authScheme: AuthScheme.bearerToken,
          ))
          .runtimeType;

      registerConfigProviders(registry, config);

      final after = registry.descriptor('glm')!
          .builder(ProviderInstance(
            apiKey: '',
            model: 'glm-5.2',
            baseUrl: '',
            maxTokens: 100,
            streamIdleTimeout: const Duration(seconds: 30),
            requestTimeout: const Duration(seconds: 30),
            authScheme: AuthScheme.bearerToken,
          ));
      expect(after.runtimeType, beforeType,
          reason: 'built-in with no wire should produce the same provider type');
      expect(after, isA<OpenAiCompatibleAdapter>());
    });

    test('wire set but no base_url is skipped (new id)', () {
      final config = UserConfig(providers: {
        'zai': ProviderConfig(wire: 'anthropic'), // no base_url
      });
      final registry = builtinRegistry();
      registerConfigProviders(registry, config);

      expect(registry.descriptor('zai'), isNull,
          reason: 'custom provider without base_url should not be registered');
    });

    test('wire set but no base_url leaves built-in untouched', () {
      final config = UserConfig(providers: {
        'glm': ProviderConfig(wire: 'anthropic'), // no base_url
      });
      final registry = builtinRegistry();
      registerConfigProviders(registry, config);

      // Built-in glm should still be OpenAI-compatible.
      final provider = registry
          .descriptor('glm')!
          .builder(ProviderInstance(
            apiKey: '',
            model: 'glm-5.2',
            baseUrl: '',
            maxTokens: 100,
            streamIdleTimeout: const Duration(seconds: 30),
            requestTimeout: const Duration(seconds: 30),
            authScheme: AuthScheme.bearerToken,
          ));
      expect(provider, isA<OpenAiCompatibleAdapter>());
    });

    test('auth resolves via env overlay for anthropic-wire custom provider',
        () {
      final config = UserConfig(providers: {
        'zai': ProviderConfig(
          authToken: 'test-token',
          wire: 'anthropic',
          baseUrl: 'https://api.z.ai/api/anthropic',
        ),
      });
      final overlay = buildEnvOverlay(config);
      final mergedEnv = <String, String>{...overlay};
      final registry = builtinRegistry(env: mergedEnv);
      registerConfigProviders(registry, config);

      final desc = registry.descriptor('zai')!;
      final auth = registry.authFor(desc, env: mergedEnv);
      expect(auth.key, 'test-token');
      expect(auth.scheme, AuthScheme.bearerToken,
          reason: 'anthropic-wire with auth_token should resolve bearer');
    });

    test('auth resolves via env overlay for api_key on custom provider', () {
      final config = UserConfig(providers: {
        'zai': ProviderConfig(
          apiKey: 'api-test-key',
          wire: 'anthropic',
          baseUrl: 'https://api.z.ai/api/anthropic',
        ),
      });
      final overlay = buildEnvOverlay(config);
      final mergedEnv = <String, String>{...overlay};
      final registry = builtinRegistry(env: mergedEnv);
      registerConfigProviders(registry, config);

      final desc = registry.descriptor('zai')!;
      final auth = registry.authFor(desc, env: mergedEnv);
      expect(auth.key, 'api-test-key');
      // authSources: [AUTH_TOKEN (bearer), API_KEY (apiKeyHeader)]
      // build() forces first authSource scheme when apiKeyOverride is set,
      // but authFor returns the matched source's scheme.
      expect(auth.scheme, AuthScheme.apiKeyHeader,
          reason:
              'anthropic-wire with api_key should resolve x-api-key scheme');
    });

    test('wire value other than anthropic/openai warns and defaults to openai',
        () {
      final config = UserConfig(providers: {
        'unknown': ProviderConfig(
          baseUrl: 'http://localhost:9999',
          wire: 'bogus',
        ),
      });
      final registry = builtinRegistry();
      registerConfigProviders(registry, config);

      final provider =
          registry.build('unknown/test', apiKeyOverride: '');
      expect(provider, isA<OpenAiCompatibleAdapter>(),
          reason: 'invalid wire should default to openai');
    });

    test('custom provider name is title-cased by default', () {
      final config = UserConfig(providers: {
        'my-provider': ProviderConfig(
          baseUrl: 'http://localhost:9999',
          wire: 'openai',
        ),
      });
      final registry = builtinRegistry();
      registerConfigProviders(registry, config);

      final desc = registry.descriptor('my-provider')!;
      expect(desc.name, 'My-provider');
    });

    test('custom provider name can be set explicitly', () {
      final config = UserConfig(providers: {
        'my-provider': ProviderConfig(
          baseUrl: 'http://localhost:9999',
          wire: 'openai',
          name: 'My Custom LLM',
        ),
      });
      final registry = builtinRegistry();
      registerConfigProviders(registry, config);

      final desc = registry.descriptor('my-provider')!;
      expect(desc.name, 'My Custom LLM');
    });

    test('no providers in config leaves registry unchanged', () {
      final registry = builtinRegistry();
      registerConfigProviders(registry, UserConfig.empty);

      // built-in descriptors still present.
      expect(registry.descriptor('anthropic'), isNotNull);
      expect(registry.descriptor('glm'), isNotNull);
    });
  });
}
