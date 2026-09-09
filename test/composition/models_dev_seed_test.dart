import 'package:tina/composition/models_dev_seed.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

/// One models.dev provider entry, with the boring fields defaulted.
ModelsDevProviderInfo info({
  required String key,
  String? name,
  List<String> envVars = const [],
  String npm = '@ai-sdk/openai-compatible',
  String? apiBase,
  Map<String, ModelInfo>? models,
}) =>
    ModelsDevProviderInfo(
      key: key,
      name: name ?? key,
      envVars: envVars,
      npm: npm,
      apiBase: apiBase,
      models: models ??
          const {
            'm-1': ModelInfo(
              id: 'm-1',
              name: 'M1',
              contextWindow: 8192,
              maxOutput: 1024,
            ),
          },
    );

void main() {
  group('registerModelsDevProviders', () {
    test('registers a credentialed OpenAI-compatible provider', () {
      final registry = builtinRegistry(env: const {});
      final added = registerModelsDevProviders(
        registry: registry,
        env: const {'MOONSHOT_API_KEY': 'sk-test'},
        providers: {
          'moonshotai': info(
            key: 'moonshotai',
            name: 'Moonshot AI',
            envVars: ['MOONSHOT_API_KEY'],
            apiBase: 'https://api.moonshot.ai/v1',
          ),
        },
      );

      expect(added, 1);
      final d = registry.descriptor('moonshotai')!;
      expect(d.name, 'Moonshot AI');
      expect(d.defaultBaseUrl, 'https://api.moonshot.ai/v1');
      expect(d.listsRemoteModels, isTrue,
          reason: 'the live /v1/models list refines the models.dev fallback');
      final envVars = d.authSources.map((s) => s.envVar);
      expect(envVars, contains('MOONSHOT_API_KEY'));
      // A `[providers.moonshotai] api_key` block exports this name even though
      // models.dev calls the credential something else.
      expect(envVars, contains('MOONSHOTAI_API_KEY'));
      expect(registry.modelsFor('moonshotai').map((m) => m.id), ['m-1']);
    });

    test('the <ID>_API_KEY a config block exports is enough on its own', () {
      final registry = builtinRegistry(env: const {});
      final added = registerModelsDevProviders(
        registry: registry,
        env: const {'MOONSHOTAI_API_KEY': 'sk-config'},
        providers: {
          'moonshotai': info(
            key: 'moonshotai',
            envVars: ['MOONSHOT_API_KEY'],
            apiBase: 'https://api.moonshot.ai/v1',
          ),
        },
      );

      expect(added, 1);
      expect(registry.descriptor('moonshotai'), isNotNull);
    });

    test('skips a provider with no credential in the environment', () {
      final registry = builtinRegistry(env: const {});
      final added = registerModelsDevProviders(
        registry: registry,
        env: const {},
        providers: {
          'moonshotai': info(
            key: 'moonshotai',
            envVars: ['MOONSHOT_API_KEY'],
            apiBase: 'https://api.moonshot.ai/v1',
          ),
        },
      );

      expect(added, 0);
      expect(registry.descriptor('moonshotai'), isNull);
    });

    test('skips wires tina cannot speak, however credentialed', () {
      final registry = builtinRegistry(env: const {});
      final added = registerModelsDevProviders(
        registry: registry,
        env: const {'GEMINI_API_KEY': 'x', 'OLLAMA_API_KEY': 'y'},
        providers: {
          'google': info(
            key: 'google',
            envVars: ['GEMINI_API_KEY'],
            npm: '@ai-sdk/google',
            apiBase: 'https://generativelanguage.googleapis.com',
          ),
          'ollama-cloud': info(
            key: 'ollama-cloud',
            envVars: ['OLLAMA_API_KEY'],
            npm: 'ollama-ai-provider',
            apiBase: 'https://ollama.com/v1',
          ),
        },
      );

      expect(added, 0);
      expect(registry.descriptor('google'), isNull);
      expect(registry.descriptor('ollama-cloud'), isNull);
    });

    test('skips entries with no base URL or no models', () {
      final registry = builtinRegistry(env: const {});
      final added = registerModelsDevProviders(
        registry: registry,
        env: const {'A_API_KEY': 'x', 'B_API_KEY': 'y'},
        providers: {
          'no-base': info(key: 'no-base', envVars: ['A_API_KEY']),
          'no-models': info(
            key: 'no-models',
            envVars: ['B_API_KEY'],
            apiBase: 'https://no-models.example/v1',
            models: const {},
          ),
        },
      );

      expect(added, 0);
      expect(registry.descriptor('no-base'), isNull);
      expect(registry.descriptor('no-models'), isNull);
    });

    test('does not duplicate a compiled provider under its models.dev id', () {
      final registry = builtinRegistry(env: const {});
      final compiledNimModels = registry.modelsFor('nim').length;
      final added = registerModelsDevProviders(
        registry: registry,
        env: const {'NVIDIA_API_KEY': 'nvapi-test'},
        providers: {
          // models.dev's key for what tina compiles as `nim`: same credential
          // env var, same host. Registering it would give one key two provider
          // rows and a second, uncurated model list.
          'nvidia': info(
            key: 'nvidia',
            name: 'NVIDIA',
            envVars: ['NVIDIA_API_KEY'],
            apiBase: 'https://integrate.api.nvidia.com/v1',
          ),
        },
      );

      expect(added, 0);
      expect(registry.descriptor('nvidia'), isNull);
      expect(registry.descriptor('nim'), isNotNull);
      expect(registry.modelsFor('nim').length, compiledNimModels,
          reason: 'the compiled list stays authoritative');
    });

    test('skips a credential already claimed by another descriptor', () {
      final registry = builtinRegistry(env: const {});
      final added = registerModelsDevProviders(
        registry: registry,
        env: const {'ANTHROPIC_API_KEY': 'sk-ant'},
        providers: {
          // A gateway on a different host, but the same env var — its key
          // would resolve to the wrong provider.
          'anthropic-gateway': info(
            key: 'anthropic-gateway',
            envVars: ['ANTHROPIC_API_KEY'],
            apiBase: 'https://gateway.example/v1',
          ),
        },
      );

      expect(added, 0);
      expect(registry.descriptor('anthropic-gateway'), isNull);
    });

    test('skips an id a compiled descriptor already owns', () {
      final registry = builtinRegistry(env: const {});
      final added = registerModelsDevProviders(
        registry: registry,
        env: const {'MISTRAL_API_KEY': 'sk-mistral'},
        providers: {
          'mistral': info(
            key: 'mistral',
            name: 'Mistral (models.dev)',
            envVars: ['MISTRAL_API_KEY'],
            apiBase: 'https://api.mistral.ai/v1',
          ),
        },
      );

      expect(added, 0);
      expect(registry.descriptor('mistral')!.name, isNot('Mistral (models.dev)'));
    });

    test('registers regional twins that share one credential', () {
      // models.dev lists moonshotai (api.moonshot.ai) and moonshotai-cn
      // (api.moonshot.cn) under the SAME MOONSHOT_API_KEY. Dropping one as a
      // "collision" would hide whichever endpoint the user actually needs.
      final registry = builtinRegistry(env: const {});
      final added = registerModelsDevProviders(
        registry: registry,
        env: const {'MOONSHOT_API_KEY': 'sk-test'},
        providers: {
          'moonshotai-cn': info(
            key: 'moonshotai-cn',
            envVars: ['MOONSHOT_API_KEY'],
            apiBase: 'https://api.moonshot.cn/v1',
          ),
          'moonshotai': info(
            key: 'moonshotai',
            envVars: ['MOONSHOT_API_KEY'],
            apiBase: 'https://api.moonshot.ai/v1',
          ),
        },
      );

      expect(added, 2);
      expect(registry.descriptor('moonshotai-cn')!.defaultBaseUrl,
          'https://api.moonshot.cn/v1');
      expect(registry.descriptor('moonshotai')!.defaultBaseUrl,
          'https://api.moonshot.ai/v1');
    });

    test('registers every eligible provider and counts them', () {
      final registry = builtinRegistry(env: const {});
      final added = registerModelsDevProviders(
        registry: registry,
        env: const {'A_API_KEY': 'x', 'B_API_KEY': 'y'},
        providers: {
          'alpha': info(
            key: 'alpha',
            envVars: ['A_API_KEY'],
            apiBase: 'https://alpha.example/v1',
          ),
          'beta': info(
            key: 'beta',
            envVars: ['B_API_KEY'],
            apiBase: 'https://beta.example/v1',
          ),
          'gamma': info(
            key: 'gamma',
            envVars: ['C_API_KEY'],
            apiBase: 'https://gamma.example/v1',
          ),
        },
      );

      expect(added, 2);
      expect(registry.descriptor('alpha'), isNotNull);
      expect(registry.descriptor('beta'), isNotNull);
      expect(registry.descriptor('gamma'), isNull);
    });
  });
}
