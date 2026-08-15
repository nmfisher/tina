import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('qwencloud descriptor', () {
    late ProviderRegistry r;

    setUp(() {
      r = ProviderRegistry(env: {});
      registerBuiltins(r);
    });

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

    test('resolves and builds as an OpenAI-compatible adapter', () {
      final built = r.build('qwencloud/qwen3.8-max', apiKeyOverride: 'k');
      expect(built, isA<OpenAiCompatibleAdapter>());
      expect(built.model, 'qwen3.8-max');
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
}
