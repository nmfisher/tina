import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('cerebras descriptor', () {
    late ProviderRegistry r;

    setUp(() {
      r = ProviderRegistry(env: {});
      registerBuiltins(r);
    });

    test('auth is CEREBRAS_API_KEY as a bearer token', () {
      final d = r.descriptor('cerebras')!;
      expect(d.authSources, hasLength(1));
      expect(d.authSources.single.envVar, 'CEREBRAS_API_KEY');
      expect(d.authSources.single.scheme, AuthScheme.bearerToken);

      final authed = ProviderRegistry(env: {'CEREBRAS_API_KEY': 'k'})
        ..register(cerebrasDescriptor);
      expect(authed.authFor(cerebrasDescriptor).key, 'k');
    });

    test('default base URL is the Cerebras v1 endpoint', () {
      expect(r.descriptor('cerebras')!.defaultBaseUrl,
          'https://api.cerebras.ai/v1');
    });

    test('catalog matches the models the platform serves', () {
      // Verified against https://api.cerebras.ai/public/v1/models (2026-08-15).
      // Every model there shares a 131,072-token context window and a
      // 40,960-token completion cap.
      final models = r.modelsFor('cerebras');
      expect(models.map((m) => m.id), unorderedEquals(<String>[
        'gpt-oss-120b',
        'gemma-4-31b',
        'zai-glm-4.7',
      ]));
      for (final m in models) {
        expect(m.contextWindow, 131072, reason: m.id);
        expect(m.maxOutput, 40960, reason: m.id);
        // All three report function calling / tools support — tina is
        // tool-driven, so this must stay true or the agent loop can't run.
        expect(m.supportsTools, isTrue, reason: m.id);
      }
    });

    test('catalogs Gemma 4 31B with vision support', () {
      final m = r.descriptor('cerebras')!.models['gemma-4-31b']!;
      expect(m.name, 'Gemma 4 31B');
      // The only multimodal model on the platform (text+vision modality).
      expect(m.supportsVision, isTrue);
      // The other two are text-only.
      expect(r.descriptor('cerebras')!.models['gpt-oss-120b']!.supportsVision,
          isFalse);
      expect(r.descriptor('cerebras')!.models['zai-glm-4.7']!.supportsVision,
          isFalse);
    });

    test('resolves and builds as an OpenAI-compatible adapter', () {
      final built = r.build('cerebras/gpt-oss-120b', apiKeyOverride: 'k');
      expect(built, isA<OpenAiCompatibleAdapter>());
      expect(built.model, 'gpt-oss-120b');

      // The dot in `zai-glm-4.7` must survive reference parsing untouched.
      final resolved = r.resolve('cerebras/zai-glm-4.7');
      expect(resolved.modelId, 'zai-glm-4.7');
    });
  });
}
