import '../openai_compatible.dart';
import '../registry.dart';

/// Qwen (Alibaba DashScope) — OpenAI-compatible "compatible mode" endpoint.
final ProviderDescriptor qwenDescriptor = ProviderDescriptor(
  id: 'qwen',
  name: 'Qwen (DashScope)',
  authSources: const [AuthSource('DASHSCOPE_API_KEY', AuthScheme.bearerToken)],
  defaultBaseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
  builder: openAiCompatibleBuilder('Qwen'),
  listsRemoteModels: true,
  models: const {
    'qwen3-coder-plus': ModelInfo(
        id: 'qwen3-coder-plus',
        name: 'Qwen3 Coder Plus',
        contextWindow: 131072,
        maxOutput: 8192),
    'qwen-max': ModelInfo(
        id: 'qwen-max',
        name: 'Qwen Max',
        contextWindow: 32768,
        maxOutput: 8192),
  },
);
