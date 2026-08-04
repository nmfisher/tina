import '../openai_compatible.dart';
import '../registry.dart';

/// Novita AI — OpenAI-compatible inference platform serving 200+ models
/// (DeepSeek, Qwen, Llama, Kimi, GLM, MiniMax, …) behind a single
/// `/v1/chat/completions` endpoint with Bearer auth.
///
/// ```toml
/// [providers.novita]
/// api_key = "YOUR_API_KEY"
/// ```
final ProviderDescriptor novitaDescriptor = ProviderDescriptor(
  id: 'novita',
  name: 'Novita AI',
  authSources: const [AuthSource('NOVITA_API_KEY', AuthScheme.bearerToken)],
  defaultBaseUrl: 'https://api.novita.ai/openai',
  builder: openAiCompatibleBuilder('Novita AI'),
  models: const {
    'deepseek-v3-0324': ModelInfo(
      id: 'deepseek-v3-0324',
      name: 'DeepSeek V3',
      contextWindow: 128000,
      maxOutput: 16384,
    ),
    'deepseek-r1-0528': ModelInfo(
      id: 'deepseek-r1-0528',
      name: 'DeepSeek R1',
      contextWindow: 128000,
      maxOutput: 16384,
    ),
    'qwen3-coder-480b-a35b-instruct': ModelInfo(
      id: 'qwen3-coder-480b-a35b-instruct',
      name: 'Qwen3 Coder 480B A35B',
      contextWindow: 131072,
      maxOutput: 8192,
    ),
    'kimi-k2-instruct': ModelInfo(
      id: 'kimi-k2-instruct',
      name: 'Kimi K2',
      contextWindow: 131072,
      maxOutput: 8192,
    ),
    'llama-3.3-70b-instruct': ModelInfo(
      id: 'llama-3.3-70b-instruct',
      name: 'Llama 3.3 70B',
      contextWindow: 131072,
      maxOutput: 4096,
    ),
    'tencent/hy3': ModelInfo(
      id: 'tencent/hy3',
      name: 'Tencent Hy3',
      contextWindow: 256000,
      maxOutput: 64000,
    ),
  },
);
