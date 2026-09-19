// Per-provider facts for the builtin catalog: the auth env vars and scheme, the
// base URL and the route it produces, the model catalog with its specs, and the
// resolution quirks a provider has.
//
// Registry-wide invariants live in `builtins_test.dart` — that every builtin
// registers, that each builds with an explicit key, and that the thirteen
// adapter providers build to [OpenAiCompatibleAdapter]. Those were previously
// re-asserted here once per provider, which is why this file carries four
// groups instead of four files; what remains is what only *this* provider can
// tell you.
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

/// The adapter a descriptor builds to, peeling the launch-slot queue that a
/// built-in `requestsPerMinute` hint wraps around it (NIM carries one).
LlmProvider adapterOf(LlmProvider built) =>
    built is RateLimitedProvider ? built.inner : built;

void main() {
  late ProviderRegistry r;

  setUp(() {
    r = ProviderRegistry(env: {});
    registerBuiltins(r);
  });

  group('cerebras descriptor', () {
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

    test('qwen3.8-27b is carried as announced-not-yet-live, provisional specs',
        () {
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

    test('a dot in a model id survives reference parsing', () {
      // `cerebras/zai-glm-4.7`: the dot must not be read as a version suffix.
      expect(r.resolve('cerebras/zai-glm-4.7').modelId, 'zai-glm-4.7');
      expect(adapterOf(r.build('cerebras/zai-glm-4.7', apiKeyOverride: 'k'))
          .model, 'zai-glm-4.7');
    });
  });

  group('hetzner descriptor', () {
    /// Verifies the Hetzner Inference descriptor against the live API facts
    /// (checked 2026-08-19), cross-referenced with models.dev's provider entry:
    /// OpenAI-compatible root `https://inference.hetzner.com/api/v1`, Bearer
    /// auth, serving the Qwen3.8-27B and Qwen3.6-35B-A3B models (both 256K
    /// context, vision-capable).
    test('auth is HETZNER_API_KEY as a Bearer token', () {
      final d = r.descriptor('hetzner')!;
      expect(d.authSources.map((s) => s.envVar).toList(), ['HETZNER_API_KEY']);
      expect(
          d.authSources.every((s) => s.scheme == AuthScheme.bearerToken),
          isTrue,
          reason: 'OpenAI-compatible — needs Authorization: Bearer');
    });

    test('default base URL omits the trailing /v1 so the adapter and live '
        'catalog both hit /api/v1/...', () {
      // chatEndpoint appends /v1/chat/completions when the base does not end
      // in /v<digits>; LiveModelsCatalog appends /v1/models unconditionally.
      // Base '.../api' (no version) makes both resolve to the verified routes;
      // a versioned base (https://...api/v1) would yield the verified-404
      // /api/v1/v1/models for the live model listing.
      final base = r.descriptor('hetzner')!.defaultBaseUrl;
      expect(base, 'https://inference.hetzner.com/api');
      expect(OpenAiCompatibleAdapter.chatEndpoint(base),
          'https://inference.hetzner.com/api/v1/chat/completions');
      expect('$base/v1/models',
          'https://inference.hetzner.com/api/v1/models');
    });

    test('catalog matches Hetzner docs (2 vision models, 256K each)', () {
      final models = r.modelsFor('hetzner');
      expect(models.map((m) => m.id), unorderedEquals(<String>[
        'Qwen3.8-27B',
        'Qwen/Qwen3.6-35B-A3B-FP8',
      ]));
      final byId = {for (final m in models) m.id: m};
      // maxOutput comes from models.dev's `limit.output` for each model, not a
      // blanket default — the two differ (32768 vs 65536).
      expect(byId['Qwen3.8-27B']!.maxOutput, 32768);
      expect(byId['Qwen/Qwen3.6-35B-A3B-FP8']!.maxOutput, 65536);
      for (final m in models) {
        expect(m.contextWindow, 262144, reason: m.id);
        expect(m.supportsTools, isTrue, reason: m.id);
        expect(m.supportsVision, isTrue, reason: m.id);
      }
    });

    test('the newest model is the default', () {
      // Config.parse uses `desc.models.keys.first` as the default model when no
      // HETZNER_MODEL env / file entry is set, so the flagship leads the map.
      expect(r.modelsFor('hetzner').first.id, 'Qwen3.8-27B');
    });

    test('builds with its display label', () {
      final built = r.build('hetzner/Qwen3.8-27B', apiKeyOverride: 'k');
      expect(adapterOf(built), isA<OpenAiCompatibleAdapter>());
      expect((built as OpenAiCompatibleAdapter).label, 'Hetzner');
    });

    test('exact-case ids resolve under the provider prefix', () {
      expect(r.resolve('hetzner/Qwen3.8-27B').descriptor.id, 'hetzner');
      // The 35B id itself contains a slash (Hugging Face org prefix), so a
      // bare reference would parse as provider "Qwen" — the prefixed form is
      // the only way to name it.
      expect(
          r.resolve('hetzner/Qwen/Qwen3.6-35B-A3B-FP8').descriptor.id,
          'hetzner');
    });
  });

  group('qwencloud descriptor', () {
    test('auth is QWENCLOUD_API_KEY first, DASHSCOPE_API_KEY fallback', () {
      final d = r.descriptor('qwencloud')!;
      expect(
          d.authSources.map((s) => s.envVar).toList(),
          ['QWENCLOUD_API_KEY', 'DASHSCOPE_API_KEY']);
      // Both sources are bearer — the endpoint is OpenAI-compatible.
      expect(d.authSources.every((s) => s.scheme == AuthScheme.bearerToken),
          isTrue);

      // The tina-conventional var wins when both are set.
      final both = ProviderRegistry(env: {
        'QWENCLOUD_API_KEY': 'qc',
        'DASHSCOPE_API_KEY': 'ds',
      })
        ..register(qwencloudDescriptor);
      expect(both.authFor(qwencloudDescriptor).key, 'qc');

      // The legacy DashScope var still works on its own.
      final legacy = ProviderRegistry(env: {'DASHSCOPE_API_KEY': 'ds'})
        ..register(qwencloudDescriptor);
      expect(legacy.authFor(qwencloudDescriptor).key, 'ds');
    });

    test('default base URL is the international compatible-mode endpoint', () {
      // The China endpoint belongs to the separate `qwen` builtin; QwenCloud's
      // default region is ap-southeast-1 (per qwencloud-ai's qwencloud_lib.py).
      expect(r.descriptor('qwencloud')!.defaultBaseUrl,
          'https://dashscope-intl.aliyuncs.com/compatible-mode/v1');
      expect(r.descriptor('qwen')!.defaultBaseUrl, isNot(equals(
          r.descriptor('qwencloud')!.defaultBaseUrl)));
    });

    test('catalog is the curated chat list with live-page specs', () {
      // Every id has a live detail page at qwencloud.com/models/<id>
      // (checked 2026-08-15); each advertises 1M context and function
      // calling. Image/video/TTS/embedding models are deliberately omitted —
      // the chat adapter cannot serve them.
      final models = r.modelsFor('qwencloud');
      expect(models.map((m) => m.id), unorderedEquals(<String>[
        'qwen3.8-max',
        'qwen3.7-plus',
        'qwen3.6-plus',
        'qwen3.5-plus',
        'qwen3-max',
        'qwen-plus',
        'qwen-flash',
        'qwen-turbo',
        'qwq-plus',
        'qwen3-coder-plus',
        'qwen3-coder-next',
        'qwen3-vl-plus',
      ]));
      for (final m in models) {
        // The platform advertises 1M (1,048,576) for all of these.
        expect(m.contextWindow, 1048576, reason: m.id);
        // maxOutput unpublished per model; 8192 is the DashScope default cap.
        expect(m.maxOutput, 8192, reason: m.id);
        // Every model page advertises function calling — tina is tool-driven,
        // so this must stay true or the agent loop can't run.
        expect(m.supportsTools, isTrue, reason: m.id);
      }
    });

    test('vision is enabled only for the multimodal models', () {
      final d = r.descriptor('qwencloud')!;
      const visionIds = ['qwen3.7-plus', 'qwen3.6-plus', 'qwen3.5-plus',
        'qwen3-vl-plus'];
      for (final entry in d.models.entries) {
        expect(entry.value.supportsVision, visionIds.contains(entry.key),
            reason: entry.key);
      }
    });

    test('bare model ids stay unambiguous against the qwen builtin', () {
      // Both providers carry `qwen3-coder-plus`; a bare reference must be
      // ambiguous (null from findModel), forcing the provider prefix.
      expect(r.findModel('qwen3-coder-plus'), isNull);
      expect(r.findModel('qwencloud/qwen3-coder-plus')?.id, 'qwen3-coder-plus');
      // Models unique to qwencloud resolve bare.
      expect(r.resolve('qwen3.8-max').descriptor.id, 'qwencloud');
    });
  });

  group('nim descriptor', () {
    test('catalogs Gemma 4 31B IT with the NIM-sourced metadata', () {
      const id = 'google/gemma-4-31b-it';
      final model = r.descriptor('nim')!.models[id];
      expect(model, isNotNull);
      expect(model!.id, id);
      expect(model.name, 'Gemma 4 31B IT');
      // NIM API ref caps max_tokens at 32768 for this model.
      expect(model.maxOutput, 32768);
      // 128K native context window (NIM's other long-context models use 131072).
      expect(model.contextWindow, 131072);
      // Gemma 4 has native function calling — tina is tool-driven, so this
      // must stay true or the agent loop can't run.
      expect(model.supportsTools, isTrue);
      // Listed under NIM's Visual Models; multimodal input is supported.
      expect(model.supportsVision, isTrue);
    });

    test('resolves and builds Gemma 4 as an OpenAI-compatible adapter', () {
      // Prefixed reference trusts the provider prefix.
      final resolved = r.resolve('nim/google/gemma-4-31b-it');
      expect(resolved.descriptor.id, 'nim');
      expect(resolved.modelId, 'google/gemma-4-31b-it');

      final built = r.build('nim/google/gemma-4-31b-it', apiKeyOverride: 'k');
      // The 40 rpm built-in hint wraps the adapter in its launch-slot queue;
      // peel it to assert the adapter the descriptor actually builds to.
      final adapter = adapterOf(built);
      expect(adapter, isA<OpenAiCompatibleAdapter>());
      expect(adapter.model, 'google/gemma-4-31b-it');
    });

    test('the observed 40 rpm ceiling spaces the queue by default', () {
      // The hint engages the launch-slot wrapper on its own — even with the
      // registry-wide limiter disabled — and installs 60 s / 40 rpm of
      // spacing on the endpoint+key queue.
      final built = r.build('nim/google/gemma-4-31b-it', apiKeyOverride: 'k');
      expect(built, isA<RateLimitedProvider>(),
          reason: 'NIM 429s at 40 req/min per key in the wild; that ceiling '
              'must hold unless the user overrides it');
      final key = (built as RateLimitedProvider).limitKey;
      expect(r.rateLimiter.minIntervalFor(key),
          const Duration(milliseconds: 1500));
    });

    test('the prefixed reference is the only valid selector', () {
      // The model id itself contains a slash (`google/...`), so
      // ModelReference.parse treats a bare `google/gemma-4-31b-it` as
      // provider=`google` (unknown). Users must prefix the provider, like
      // OpenRouter's nested ids.
      expect(() => r.resolve('google/gemma-4-31b-it'),
          throwsA(isA<ProviderRegistryException>()));
      expect(r.resolve('nim/google/gemma-4-31b-it').descriptor.id, 'nim');
    });
  });
}
