import '../openai_compatible.dart';
import '../registry.dart';

/// DeepSeek — OpenAI-compatible. `deepseek-reasoner` emits a separate
/// `reasoning_content` field (dropped by the adapter) and has limited tool
/// support, so it is marked [ModelInfo.supportsTools] false.
final ProviderDescriptor deepseekDescriptor = ProviderDescriptor(
  id: 'deepseek',
  name: 'DeepSeek',
  authSources: const [AuthSource('DEEPSEEK_API_KEY', AuthScheme.bearerToken)],
  defaultBaseUrl: 'https://api.deepseek.com',
  builder: openAiCompatibleBuilder('DeepSeek'),
  models: const {
    'deepseek-chat': ModelInfo(
        id: 'deepseek-chat',
        name: 'DeepSeek V3 (chat)',
        contextWindow: 65536,
        maxOutput: 8192),
    'deepseek-reasoner': ModelInfo(
        id: 'deepseek-reasoner',
        name: 'DeepSeek R1 (reasoner)',
        contextWindow: 65536,
        maxOutput: 32768,
        supportsTools: false),
  },
);
