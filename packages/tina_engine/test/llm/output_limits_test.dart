import 'dart:convert';

import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_http.dart';

void main() {
  for (final source in ['live', 'models.dev missing', 'models.dev zero']) {
    test('$source unknown limit does not clamp the actual wire request',
        () async {
      final capture = CapturedRequest();
      final registry = ProviderRegistry(env: {});
      final model = modelsDevModelInfo('new-model', {
        if (source.endsWith('zero')) 'limit': {'output': 0},
      })!;
      registry.register(ProviderDescriptor(
        id: 'custom',
        name: 'custom',
        authSources: const [],
        defaultBaseUrl: 'https://example.test',
        models: source == 'live' ? const {} : {'new-model': model},
        builder: (c) => OpenAiCompatibleAdapter(
          apiKey: '',
          model: c.model,
          maxTokens: c.maxTokens,
          reasoningEffort: c.reasoningEffort,
          client: capture.client,
        ),
      ));
      if (source == 'live') {
        registry.catalog = LiveModelsCatalog(env: {});
        addTearDown(registry.catalog!.close);
      }
      final factory = RuntimeProviderFactory(registry);
      final provider = factory.build('custom/new-model',
          maxTokens: 2000000, reasoningEffort: 'high');
      addTearDown(provider.close);
      await provider.send(system: '', messages: [], tools: []).drain<void>();
      final body = jsonDecode(capture.body!) as Map;
      expect(body['max_tokens'], 2000000);
      expect(body['reasoning_effort'], 'high');
      expect(registry.findModel('custom/new-model')!.maxOutput, isNull);
    });
  }

  test('provider override wins over overlay, while a lower request cap wins',
      () {
    final registry = ProviderRegistry(env: {});
    final received = <int>[];
    registry.register(ProviderDescriptor(
      id: 'custom',
      name: 'custom',
      authSources: const [],
      defaultBaseUrl: 'https://example.test',
      maxOutputOverride: 131072,
      builder: (c) {
        received.add(c.maxTokens);
        return OpenAiCompatibleAdapter(apiKey: '', model: c.model);
      },
    ));
    registry.catalog = _OutputCatalog(8192);
    final factory = RuntimeProviderFactory(registry);
    for (final requested in [2000000, 65536, null]) {
      final provider = factory.build('custom/new-model', maxTokens: requested);
      provider.close();
    }
    expect(received, [131072, 65536, ProviderRegistry.defaultMaxTokens]);
  });

  test('unknown overlay preserves a verified compiled ceiling', () {
    final registry = builtinRegistry(env: {})..catalog = _OutputCatalog(null);
    final provider = registry.build('glm/glm-5.3', maxTokens: 2000000);
    addTearDown(provider.close);
    expect((provider as OpenAiCompatibleAdapter).maxTokens, 131072);
  });

  test('GLM 5.3 variants have published limits', () {
    final registry = builtinRegistry(env: {});
    for (final id in ['glm-5.3', 'glm-5.3-flash']) {
      final model = registry.findModel('glm/$id')!;
      expect(model.maxOutput, 131072);
      expect(model.contextWindow, 1000000);
    }
    expect(registry.findModel('glm/glm-5.3-flash')!.supportsVision, isTrue);
  });
}

class _OutputCatalog extends ModelCatalog {
  final int? output;
  _OutputCatalog(this.output);
  @override
  ModelInfo? findModel(ProviderDescriptor desc, String modelId) => ModelInfo(
      id: modelId, name: modelId, contextWindow: 131072, maxOutput: output);
  @override
  List<ModelInfo> modelsFor(ProviderDescriptor desc) => const [];
  @override
  bool hasAny(ProviderDescriptor desc) => true;
}
