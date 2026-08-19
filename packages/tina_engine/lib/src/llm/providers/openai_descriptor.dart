import '../openai_compatible.dart';
import '../registry.dart';

/// OpenAI — the canonical OpenAI-compatible endpoint.
final ProviderDescriptor openaiDescriptor = ProviderDescriptor(
  id: 'openai',
  name: 'OpenAI',
  authSources: const [AuthSource('OPENAI_API_KEY', AuthScheme.bearerToken)],
  defaultBaseUrl: 'https://api.openai.com',
  builder: openAiCompatibleBuilder('OpenAI'),
  listsRemoteModels: true,
  models: const {
    'gpt-4o': ModelInfo(
        id: 'gpt-4o', name: 'GPT-4o', contextWindow: 128000, maxOutput: 16384),
  },
);
