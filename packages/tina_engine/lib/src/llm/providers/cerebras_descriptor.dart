import '../openai_compatible.dart';
import '../registry.dart';

/// Cerebras Inference — OpenAI-compatible.
///
/// Catalog verified against the public models endpoint
/// (https://api.cerebras.ai/public/v1/models) on 2026-08-15. All three models
/// share a 131,072-token context window and a 40,960-token completion cap.
final ProviderDescriptor cerebrasDescriptor = ProviderDescriptor(
  id: 'cerebras',
  name: 'Cerebras',
  authSources: const [AuthSource('CEREBRAS_API_KEY', AuthScheme.bearerToken)],
  defaultBaseUrl: 'https://api.cerebras.ai/v1',
  builder: openAiCompatibleBuilder('Cerebras'),
  models: const {
    'gpt-oss-120b': ModelInfo(
        id: 'gpt-oss-120b',
        name: 'OpenAI GPT OSS',
        contextWindow: 131072,
        maxOutput: 40960),
    'gemma-4-31b': ModelInfo(
        id: 'gemma-4-31b',
        name: 'Gemma 4 31B',
        contextWindow: 131072,
        maxOutput: 40960,
        supportsVision: true),
    'zai-glm-4.7': ModelInfo(
        id: 'zai-glm-4.7',
        name: 'Z.ai GLM 4.7',
        contextWindow: 131072,
        maxOutput: 40960),
  },
);
