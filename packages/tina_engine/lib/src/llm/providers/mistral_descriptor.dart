import '../openai_compatible.dart';
import '../registry.dart';

/// Mistral — OpenAI-compatible. Codestral is the coding-focused model.
final ProviderDescriptor mistralDescriptor = ProviderDescriptor(
  id: 'mistral',
  name: 'Mistral',
  authSources: const [AuthSource('MISTRAL_API_KEY', AuthScheme.bearerToken)],
  defaultBaseUrl: 'https://api.mistral.ai/v1',
  builder: openAiCompatibleBuilder('Mistral'),
  listsRemoteModels: true,
  models: const {
    'mistral-large-latest': ModelInfo(
        id: 'mistral-large-latest',
        name: 'Mistral Large',
        contextWindow: 131072,
        maxOutput: 8192),
    'codestral-latest': ModelInfo(
        id: 'codestral-latest',
        name: 'Codestral',
        contextWindow: 262144,
        maxOutput: 8192),
  },
);
