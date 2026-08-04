import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('nim descriptor', () {
    late ProviderRegistry r;

    setUp(() {
      r = ProviderRegistry(env: {});
      registerBuiltins(r);
    });

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
      expect(built, isA<OpenAiCompatibleAdapter>());
      expect(built.model, 'google/gemma-4-31b-it');
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
