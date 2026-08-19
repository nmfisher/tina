import '../openai_compatible.dart';
import '../registry.dart';

/// OpenRouter — OpenAI-compatible gateway serving 400+ models (OpenAI,
/// Anthropic, Google, Meta, Mistral, DeepSeek, Qwen, …) behind a single
/// `/v1/chat/completions` endpoint with Bearer auth.
///
/// ```toml
/// [providers.openrouter]
/// api_key = "sk-or-..."
/// ```
final ProviderDescriptor openrouterDescriptor = ProviderDescriptor(
  id: 'openrouter',
  name: 'OpenRouter',
  authSources: const [
    AuthSource('OPENROUTER_API_KEY', AuthScheme.bearerToken),
  ],
  defaultBaseUrl: 'https://openrouter.ai/api/v1',
  builder: openAiCompatibleBuilder('OpenRouter'),
  listsRemoteModels: true,
  models: const {
    'openai/gpt-4o': ModelInfo(
      id: 'openai/gpt-4o',
      name: 'OpenAI GPT-4o',
      contextWindow: 128000,
      maxOutput: 16384,
    ),
    'anthropic/claude-sonnet-4-6': ModelInfo(
      id: 'anthropic/claude-sonnet-4-6',
      name: 'Claude Sonnet 4.6',
      contextWindow: 200000,
      maxOutput: 8192,
    ),
    'google/gemini-2.5-pro': ModelInfo(
      id: 'google/gemini-2.5-pro',
      name: 'Gemini 2.5 Pro',
      contextWindow: 1048576,
      maxOutput: 8192,
    ),
    'deepseek/deepseek-v4-flash': ModelInfo(
      id: 'deepseek/deepseek-v4-flash',
      name: 'DeepSeek V4 Flash',
      contextWindow: 128000,
      maxOutput: 16384,
    ),
    'meta-llama/llama-3.3-70b-instruct': ModelInfo(
      id: 'meta-llama/llama-3.3-70b-instruct',
      name: 'Llama 3.3 70B',
      contextWindow: 131072,
      maxOutput: 4096,
    ),
    'qwen/qwen3-coder-plus': ModelInfo(
      id: 'qwen/qwen3-coder-plus',
      name: 'Qwen3 Coder Plus',
      contextWindow: 131072,
      maxOutput: 8192,
    ),
    'tencent/hy3:free': ModelInfo(
      id: 'tencent/hy3:free',
      name: 'Tencent Hy3 (free)',
      contextWindow: 256000,
      maxOutput: 64000,
    ),
  },
);
