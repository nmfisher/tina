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

  group('registerConfigProviders pools', () {
    // Two endpoints serving the same models, plus a pool over them — the
    // shape the feature exists for: one 40-RPM provider becomes two.
    UserConfig twoMemberConfig() => UserConfig(providers: {
          'a': ProviderConfig(
              baseUrl: 'https://a.test/v1', wire: 'openai', apiKey: 'ka'),
          'b': ProviderConfig(
              baseUrl: 'https://b.test/v1', wire: 'openai', apiKey: 'kb'),
          'mypool': ProviderConfig(members: ['a', 'b']),
        });

    test('a pool block builds a PooledProvider over its members', () {
      final config = twoMemberConfig();
      final overlay = buildEnvOverlay(config);
      final registry = builtinRegistry(env: overlay);
      registerConfigProviders(registry, config);

      final pool = registry.build('mypool/llama3');
      expect(pool, isA<PooledProvider>());
      expect((pool as PooledProvider).members, hasLength(2));
      expect(pool.model, 'llama3');
    });

    test('the pool needs no base_url of its own', () {
      // twoMemberConfig's pool block has only members — if base_url were
      // required the pool would have been skipped and build would throw.
      final config = twoMemberConfig();
      final registry = builtinRegistry(env: buildEnvOverlay(config));
      registerConfigProviders(registry, config);

      expect(registry.descriptor('mypool'), isNotNull);
    });

    test('the pool catalog is the union of member catalogs', () {
      final config = UserConfig(providers: {
        'a': ProviderConfig(
            baseUrl: 'https://a.test/v1',
            wire: 'openai',
            disabledModels: const <String>{}),
        'b': ProviderConfig(
            baseUrl: 'https://b.test/v1',
            wire: 'openai',
            disabledModels: const {'glm-5.2'}),
        'mypool': ProviderConfig(members: ['a', 'b']),
      });
      final registry = builtinRegistry(env: buildEnvOverlay(config));
      registerConfigProviders(registry, config);

      final ids = registry.modelsFor('mypool').map((m) => m.id).toSet();
      final aIds = registry.modelsFor('a').map((m) => m.id).toSet();
      final bIds = registry.modelsFor('b').map((m) => m.id).toSet();
      expect(ids, aIds.union(bIds),
          reason: 'everything any member serves is pickable through the pool');
    });

    test('a pool declared BEFORE its members still resolves', () {
      final config = UserConfig(providers: {
        'mypool': ProviderConfig(members: ['a', 'b']), // listed first
        'a': ProviderConfig(baseUrl: 'https://a.test/v1', wire: 'openai'),
        'b': ProviderConfig(baseUrl: 'https://b.test/v1', wire: 'openai'),
      });
      final registry = builtinRegistry(env: buildEnvOverlay(config));
      registerConfigProviders(registry, config);

      expect(registry.build('mypool/llama3'), isA<PooledProvider>(),
          reason: 'pools register in a second pass, so table order is free');
    });

    test('a pool naming an unknown member is skipped', () {
      final config = UserConfig(providers: {
        'mypool': ProviderConfig(members: ['a', 'nope']),
        'a': ProviderConfig(baseUrl: 'https://a.test/v1', wire: 'openai'),
      });
      final registry = builtinRegistry(env: buildEnvOverlay(config));
      registerConfigProviders(registry, config);

      expect(registry.descriptor('mypool'), isNull,
          reason: 'a pool over a phantom member would 404 every rotation');
    });

    test('a pool over another pool is skipped', () {
      final config = UserConfig(providers: {
        'a': ProviderConfig(baseUrl: 'https://a.test/v1', wire: 'openai'),
        'inner': ProviderConfig(members: ['a']),
        'outer': ProviderConfig(members: ['inner']),
      });
      final registry = builtinRegistry(env: buildEnvOverlay(config));
      registerConfigProviders(registry, config);

      expect(registry.descriptor('inner'), isNotNull);
      expect(registry.descriptor('outer'), isNull,
          reason: 'nested pools are not supported and must not half-register');
    });

    test('a pool listing itself is skipped', () {
      final config = UserConfig(providers: {
        'a': ProviderConfig(baseUrl: 'https://a.test/v1', wire: 'openai'),
        'loop': ProviderConfig(members: ['loop', 'a']),
      });
      final registry = builtinRegistry(env: buildEnvOverlay(config));
      registerConfigProviders(registry, config);

      expect(registry.descriptor('loop'), isNull);
    });

    test('a member config block with an empty members list is a plain provider',
        () {
      final config = UserConfig(providers: {
        'a': ProviderConfig(baseUrl: 'https://a.test/v1', wire: 'openai'),
        'empty': ProviderConfig(members: const [], baseUrl: '', wire: null),
      });
      final registry = builtinRegistry(env: buildEnvOverlay(config));
      registerConfigProviders(registry, config);

      // members: [] parses to null (fromMap drops empty lists), so 'empty'
      // goes down the wire path — and with no base_url it is skipped rather
      // than registering a pool over nothing.
      expect(registry.descriptor('empty'), isNull);
    });
  });
}
