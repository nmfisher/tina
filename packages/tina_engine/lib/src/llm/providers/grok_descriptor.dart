import '../openai_compatible.dart';
import '../registry.dart';

/// Grok (xAI) — OpenAI-compatible.
final ProviderDescriptor grokDescriptor = ProviderDescriptor(
  id: 'grok',
  name: 'Grok (xAI)',
  authSources: const [AuthSource('XAI_API_KEY', AuthScheme.bearerToken)],
  defaultBaseUrl: 'https://api.x.ai/v1',
  builder: openAiCompatibleBuilder('Grok'),
  models: const {
    'grok-4': ModelInfo(
        id: 'grok-4', name: 'Grok 4', contextWindow: 131072, maxOutput: 8192),
    'grok-code-fast-1': ModelInfo(
        id: 'grok-code-fast-1',
        name: 'Grok Code Fast',
        contextWindow: 131072,
        maxOutput: 8192),
  },
);
