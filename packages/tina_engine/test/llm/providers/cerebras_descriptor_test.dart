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
      // The three live models verified against
      // https://api.cerebras.ai/public/v1/models (2026-08-15), plus the
      // announced-not-yet-live qwen3.8-27b (see its dedicated test below).
      // Every model there shares a 131,072-token context window and a
      // 40,960-token completion cap.
      final models = r.modelsFor('cerebras');
      expect(models.map((m) => m.id), unorderedEquals(<String>[
        'qwen3.8-27b',
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

    test('qwen3.8-27b is carried as announced-not-yet-live, provisional specs', () {
      // Cerebras announced this model (2026-08-15 email) but the platform
      // does not serve it yet: /public/v1/models omits it and the per-model
      // endpoint 404s. Authorized as a preemptive add. The platform has
      // published no specs, so the entry borrows the platform's uniform
      // limits rather than the open model's native 262144 context. When the
      // model goes live, re-verify against /public/v1/models and correct the
      // entry — this test then pins the corrected values.
      final m = r.descriptor('cerebras')!.models['qwen3.8-27b']!;
      expect(m.name, 'Qwen3.8 27B');
      expect(m.contextWindow, 131072);
      expect(m.maxOutput, 40960);
      // The open-weights model ships a vision encoder, but whether Cerebras
      // serves it is unknown — conservative false so images are never sent.
      expect(m.supportsVision, isFalse);

      // It must already be resolvable so configs can reference it today.
      final resolved = r.resolve('cerebras/qwen3.8-27b');
      expect(resolved.modelId, 'qwen3.8-27b');
      final built = r.build('cerebras/qwen3.8-27b', apiKeyOverride: 'k');
      expect(built, isA<OpenAiCompatibleAdapter>());
      expect(built.model, 'qwen3.8-27b');
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
