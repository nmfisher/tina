import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

/// Verifies the Hetzner Inference descriptor against the live API facts
/// (checked 2026-08-19), cross-referenced with models.dev's provider entry:
/// OpenAI-compatible root `https://inference.hetzner.com/api/v1`, Bearer auth,
/// serving the Qwen3.8-27B and Qwen3.6-35B-A3B models (both 256K context,
/// vision-capable).
void main() {
  group('hetzner descriptor', () {
    late ProviderRegistry r;

    setUp(() {
      r = ProviderRegistry(env: {});
      registerBuiltins(r);
    });

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

    test('resolves and builds as an OpenAI-compatible adapter', () {
      final built = r.build('hetzner/Qwen3.8-27B', apiKeyOverride: 'k');
      expect(built, isA<OpenAiCompatibleAdapter>());
      expect(built.model, 'Qwen3.8-27B');
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
}
