import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('registerBuiltins', () {
    test('registers all sixteen providers, sorted', () {
      final r = ProviderRegistry(env: {});
      registerBuiltins(r);
      expect(r.providerIds, [
        'anthropic',
        'cerebras',
        'deepseek',
        'gemini',
        'glm',
        'grok',
        'hetzner',
        'longcat',
        'mistral',
        'nim',
        'novita',
        'openai',
        'openrouter',
        'qwen',
        'qwencloud',
        'tencent',
      ]);
    });

    test('every built-in builds with an explicit key', () {
      final r = ProviderRegistry(env: {});
      registerBuiltins(r);
      for (final id in r.providerIds) {
        final model = r.modelsFor(id).first.id;
        expect(r.build('$id/$model', apiKeyOverride: 'k').model, model,
            reason: id);
      }
    });

    test('custom-wire providers build to their own type', () {
      final r = ProviderRegistry(env: {});
      registerBuiltins(r);
      expect(r.build('anthropic/claude-sonnet-4-6', apiKeyOverride: 'k'),
          isA<AnthropicProvider>());
      expect(r.build('tencent/deepseek-v4-pro', apiKeyOverride: 'k'),
          isA<AnthropicProvider>());
      expect(r.build('gemini/gemini-2.5-pro', apiKeyOverride: 'k'),
          isA<GeminiProvider>());
    });

    test('the thirteen adapter-based providers build to OpenAiCompatibleAdapter', () {
      final r = ProviderRegistry(env: {});
      registerBuiltins(r);
      const adapterIds = ['cerebras', 'openai', 'openrouter', 'deepseek', 'glm', 'qwen', 'qwencloud', 'grok', 'longcat', 'mistral', 'nim', 'novita', 'hetzner'];
      for (final id in adapterIds) {
        final model = r.modelsFor(id).first.id;
        expect(r.build('$id/$model', apiKeyOverride: 'k'),
            isA<OpenAiCompatibleAdapter>(),
            reason: id);
      }
    });

    test('tencent useBearerAuth follows the winning env var', () {
      final r1 = ProviderRegistry(env: {'TENCENT_AUTH_TOKEN': 'tok'});
      registerBuiltins(r1);
      expect(
          (r1.build('tencent/deepseek-v4-pro') as AnthropicProvider)
              .useBearerAuth,
          isTrue);

      final r2 = ProviderRegistry(env: {'TENCENT_API_KEY': 'k'});
      registerBuiltins(r2);
      expect(
          (r2.build('tencent/deepseek-v4-pro') as AnthropicProvider)
              .useBearerAuth,
          isFalse);
    });

    test('anthropic useBearerAuth follows the winning env var', () {
      final r1 = ProviderRegistry(env: {'ANTHROPIC_AUTH_TOKEN': 'tok'});
      registerBuiltins(r1);
      expect(
          (r1.build('anthropic/claude-sonnet-4-6') as AnthropicProvider)
              .useBearerAuth,
          isTrue);

      final r2 = ProviderRegistry(env: {'ANTHROPIC_API_KEY': 'k'});
      registerBuiltins(r2);
      expect(
          (r2.build('anthropic/claude-sonnet-4-6') as AnthropicProvider)
              .useBearerAuth,
          isFalse);
    });

    test('bare flagship models resolve to their provider', () {
      final r = ProviderRegistry(env: {});
      registerBuiltins(r);
      expect(r.findModel('gpt-4o')?.id, 'gpt-4o');
      expect(r.resolve('glm-4.6').descriptor.id, 'glm');
      expect(r.resolve('deepseek-chat').descriptor.id, 'deepseek');
    });
  });
}
