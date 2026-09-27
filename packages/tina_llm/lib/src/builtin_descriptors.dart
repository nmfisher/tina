/// The sixteen built-in provider descriptors, ported from the old
/// engine's `providers/` directory with every wire, base URL, key
/// variable, and model figure intact. Keys are environment-variable
/// *names* — the values are read from the environment at runtime and
/// never appear in source, tests, or logs.
library;

import 'descriptor.dart';
import 'gemini_provider.dart' show geminiBaseUrl;

const ProviderDescriptor _anthropic = ProviderDescriptor(
  id: 'anthropic',
  name: 'Anthropic',
  wire: ProviderWire.anthropic,
  baseUrl: 'https://api.anthropic.com',
  keyEnvVar: 'TINA_LLM_TOKEN',
  keyStyle: ProviderKeyStyle.header,
  models: {
    'claude-sonnet-4-6': ModelInfo(
      id: 'claude-sonnet-4-6',
      name: 'Claude Sonnet 4.6',
      contextWindow: 200000,
      maxOutput: 64000,
      supportsTools: true,
    ),
  },
);

const ProviderDescriptor _openai = ProviderDescriptor(
  id: 'openai',
  name: 'OpenAI',
  wire: ProviderWire.openAiCompatible,
  baseUrl: 'https://api.openai.com/v1',
  keyEnvVar: 'OPENAI_API_KEY',
  keyStyle: ProviderKeyStyle.bearer,
  models: {
    'gpt-4o': ModelInfo(
      id: 'gpt-4o',
      name: 'GPT-4o',
      contextWindow: 128000,
      maxOutput: 16384,
      supportsTools: true,
    ),
  },
);

const ProviderDescriptor _openrouter = ProviderDescriptor(
  id: 'openrouter',
  name: 'OpenRouter',
  wire: ProviderWire.openAiCompatible,
  baseUrl: 'https://openrouter.ai/api/v1',
  keyEnvVar: 'OPENROUTER_API_KEY',
  keyStyle: ProviderKeyStyle.bearer,
  models: {
    'openai/gpt-4o': ModelInfo(
      id: 'openai/gpt-4o',
      name: 'OpenAI GPT-4o',
      contextWindow: 128000,
      maxOutput: 16384,
      supportsTools: true,
    ),
    'anthropic/claude-sonnet-4-6': ModelInfo(
      id: 'anthropic/claude-sonnet-4-6',
      name: 'Claude Sonnet 4.6',
      contextWindow: 200000,
      maxOutput: 8192,
      supportsTools: true,
    ),
    'google/gemini-2.5-pro': ModelInfo(
      id: 'google/gemini-2.5-pro',
      name: 'Gemini 2.5 Pro',
      contextWindow: 1048576,
      maxOutput: 8192,
      supportsTools: true,
    ),
    'deepseek/deepseek-v4-flash': ModelInfo(
      id: 'deepseek/deepseek-v4-flash',
      name: 'DeepSeek V4 Flash',
      contextWindow: 128000,
      maxOutput: 16384,
      supportsTools: true,
    ),
    'meta-llama/llama-3.3-70b-instruct': ModelInfo(
      id: 'meta-llama/llama-3.3-70b-instruct',
      name: 'Llama 3.3 70B',
      contextWindow: 131072,
      maxOutput: 4096,
      supportsTools: true,
    ),
    'qwen/qwen3-coder-plus': ModelInfo(
      id: 'qwen/qwen3-coder-plus',
      name: 'Qwen3 Coder Plus',
      contextWindow: 131072,
      maxOutput: 8192,
      supportsTools: true,
    ),
    'tencent/hy3:free': ModelInfo(
      id: 'tencent/hy3:free',
      name: 'Tencent Hy3 (free)',
      contextWindow: 256000,
      maxOutput: 64000,
      supportsTools: true,
    ),
  },
);

const ProviderDescriptor _cerebras = ProviderDescriptor(
  id: 'cerebras',
  name: 'Cerebras',
  wire: ProviderWire.openAiCompatible,
  baseUrl: 'https://api.cerebras.ai/v1',
  keyEnvVar: 'CEREBRAS_API_KEY',
  keyStyle: ProviderKeyStyle.bearer,
  models: {
    'qwen-3-coder-480b': ModelInfo(
      id: 'qwen-3-coder-480b',
      name: 'Qwen3 Coder 480B',
      contextWindow: 131072,
      maxOutput: 8192,
      supportsTools: true,
    ),
  },
);

const ProviderDescriptor _deepseek = ProviderDescriptor(
  id: 'deepseek',
  name: 'DeepSeek',
  wire: ProviderWire.openAiCompatible,
  baseUrl: 'https://api.deepseek.com/v1',
  keyEnvVar: 'DEEPSEEK_API_KEY',
  keyStyle: ProviderKeyStyle.bearer,
  models: {
    'deepseek-chat': ModelInfo(
      id: 'deepseek-chat',
      name: 'DeepSeek Chat',
      contextWindow: 131072,
      maxOutput: 8192,
      supportsTools: true,
    ),
    'deepseek-reasoner': ModelInfo(
      id: 'deepseek-reasoner',
      name: 'DeepSeek Reasoner',
      contextWindow: 131072,
      maxOutput: 8192,
      supportsTools: true,
    ),
  },
);

const ProviderDescriptor _gemini = ProviderDescriptor(
  id: 'gemini',
  name: 'Google Gemini',
  wire: ProviderWire.gemini,
  baseUrl: geminiBaseUrl,
  keyEnvVar: 'GEMINI_API_KEY',
  keyStyle: ProviderKeyStyle.header,
  models: {
    'gemini-2.5-pro': ModelInfo(
      id: 'gemini-2.5-pro',
      name: 'Gemini 2.5 Pro',
      contextWindow: 1048576,
      maxOutput: 8192,
      supportsTools: true,
      supportsVision: true,
    ),
    'gemini-2.5-flash': ModelInfo(
      id: 'gemini-2.5-flash',
      name: 'Gemini 2.5 Flash',
      contextWindow: 1048576,
      maxOutput: 8192,
      supportsTools: true,
      supportsVision: true,
    ),
  },
);

const ProviderDescriptor _glm = ProviderDescriptor(
  id: 'glm',
  name: 'GLM (Zhipu)',
  wire: ProviderWire.openAiCompatible,
  baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
  keyEnvVar: 'GLM_API_KEY',
  keyStyle: ProviderKeyStyle.bearer,
  models: {
    'glm-4.6': ModelInfo(
      id: 'glm-4.6',
      name: 'GLM-4.6',
      contextWindow: 131072,
      maxOutput: 8192,
      supportsTools: true,
    ),
    'glm-4.6v': ModelInfo(
      id: 'glm-4.6v',
      name: 'GLM-4.6V (vision)',
      contextWindow: 131072,
      maxOutput: 8192,
      supportsTools: true,
      supportsVision: true,
    ),
    'glm-5.2': ModelInfo(
      id: 'glm-5.2',
      name: 'GLM-5.2',
      contextWindow: 131072,
      maxOutput: 8192,
      supportsTools: true,
    ),
    // https://docs.z.ai/guides/llm/glm-5.3
    // https://docs.z.ai/guides/llm/glm-5.3-flash (verified 2026-09-15).
    'glm-5.3': ModelInfo(
      id: 'glm-5.3',
      name: 'GLM-5.3',
      contextWindow: 1000000,
      maxOutput: 131072,
      supportsTools: true,
    ),
    'glm-5.3-flash': ModelInfo(
      id: 'glm-5.3-flash',
      name: 'GLM-5.3-Flash',
      contextWindow: 1000000,
      maxOutput: 131072,
      supportsTools: true,
      supportsVision: true,
    ),
  },
);

const ProviderDescriptor _grok = ProviderDescriptor(
  id: 'grok',
  name: 'Grok (xAI)',
  wire: ProviderWire.openAiCompatible,
  baseUrl: 'https://api.x.ai/v1',
  keyEnvVar: 'XAI_API_KEY',
  keyStyle: ProviderKeyStyle.bearer,
  models: {
    'grok-4': ModelInfo(
      id: 'grok-4',
      name: 'Grok 4',
      contextWindow: 131072,
      maxOutput: 8192,
      supportsTools: true,
    ),
    'grok-code-fast-1': ModelInfo(
      id: 'grok-code-fast-1',
      name: 'Grok Code Fast',
      contextWindow: 131072,
      maxOutput: 8192,
      supportsTools: true,
    ),
  },
);

const ProviderDescriptor _hetzner = ProviderDescriptor(
  id: 'hetzner',
  name: 'Hetzner Cloud',
  wire: ProviderWire.openAiCompatible,
  baseUrl: 'https://inference.hetzner.cloud/v1',
  keyEnvVar: 'HETZNER_API_KEY',
  keyStyle: ProviderKeyStyle.bearer,
  models: {
    'deepseek-v3': ModelInfo(
      id: 'deepseek-v3',
      name: 'DeepSeek V3',
      contextWindow: 65536,
      maxOutput: 8192,
      supportsTools: true,
    ),
  },
);

const ProviderDescriptor _longcat = ProviderDescriptor(
  id: 'longcat',
  name: 'LongCat',
  wire: ProviderWire.openAiCompatible,
  baseUrl: 'https://api.longcat.chat/openai/v1',
  keyEnvVar: 'LONGCAT_API_KEY',
  keyStyle: ProviderKeyStyle.bearer,
  models: {
    'LongCat-Flash-Chat': ModelInfo(
      id: 'LongCat-Flash-Chat',
      name: 'LongCat Flash Chat',
      contextWindow: 128000,
      maxOutput: 8192,
      supportsTools: true,
    ),
  },
);

const ProviderDescriptor _mistral = ProviderDescriptor(
  id: 'mistral',
  name: 'Mistral',
  wire: ProviderWire.openAiCompatible,
  baseUrl: 'https://api.mistral.ai/v1',
  keyEnvVar: 'MISTRAL_API_KEY',
  keyStyle: ProviderKeyStyle.bearer,
  models: {
    'mistral-large-latest': ModelInfo(
      id: 'mistral-large-latest',
      name: 'Mistral Large',
      contextWindow: 131072,
      maxOutput: 8192,
      supportsTools: true,
    ),
  },
);

const ProviderDescriptor _nim = ProviderDescriptor(
  id: 'nim',
  name: 'NVIDIA NIM',
  wire: ProviderWire.openAiCompatible,
  baseUrl: 'https://integrate.api.nvidia.com/v1',
  keyEnvVar: 'NVIDIA_API_KEY',
  keyStyle: ProviderKeyStyle.bearer,
  models: {},
);

const ProviderDescriptor _novita = ProviderDescriptor(
  id: 'novita',
  name: 'Novita',
  wire: ProviderWire.openAiCompatible,
  baseUrl: 'https://api.novita.ai/openai/v1',
  keyEnvVar: 'NOVITA_API_KEY',
  keyStyle: ProviderKeyStyle.bearer,
  models: {
    'deepseek/deepseek-v3.2-exp': ModelInfo(
      id: 'deepseek/deepseek-v3.2-exp',
      name: 'DeepSeek V3.2 Exp',
      contextWindow: 131072,
      maxOutput: 8192,
      supportsTools: true,
    ),
  },
);

const ProviderDescriptor _qwen = ProviderDescriptor(
  id: 'qwen',
  name: 'Qwen (International)',
  wire: ProviderWire.openAiCompatible,
  baseUrl: 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',
  keyEnvVar: 'QWEN_API_KEY',
  keyStyle: ProviderKeyStyle.bearer,
  models: {
    'qwen3-coder-plus': ModelInfo(
      id: 'qwen3-coder-plus',
      name: 'Qwen3 Coder Plus',
      contextWindow: 131072,
      maxOutput: 8192,
      supportsTools: true,
    ),
  },
);

const ProviderDescriptor _qwencloud = ProviderDescriptor(
  id: 'qwencloud',
  name: 'Qwen (China)',
  wire: ProviderWire.openAiCompatible,
  baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
  keyEnvVar: 'QWEN_API_KEY',
  keyStyle: ProviderKeyStyle.bearer,
  models: {
    'qwen3-coder-plus': ModelInfo(
      id: 'qwen3-coder-plus',
      name: 'Qwen3 Coder Plus',
      contextWindow: 131072,
      maxOutput: 8192,
      supportsTools: true,
    ),
  },
);

const ProviderDescriptor _tencent = ProviderDescriptor(
  id: 'tencent',
  name: 'Tencent Cloud',
  wire: ProviderWire.openAiCompatible,
  baseUrl: 'https://api.lkeap.cloud.tencent.com/v1',
  keyEnvVar: 'TENCENT_API_KEY',
  keyStyle: ProviderKeyStyle.bearer,
  models: {
    'deepseek-v3.1': ModelInfo(
      id: 'deepseek-v3.1',
      name: 'DeepSeek V3.1',
      contextWindow: 131072,
      maxOutput: 8192,
      supportsTools: true,
    ),
  },
);

/// Every built-in provider, in the old registry's registration order.
const List<ProviderDescriptor> builtinDescriptors = [
  _anthropic,
  _cerebras,
  _gemini,
  _openai,
  _openrouter,
  _deepseek,
  _glm,
  _grok,
  _hetzner,
  _longcat,
  _mistral,
  _nim,
  _novita,
  _qwen,
  _qwencloud,
  _tencent,
];

/// Look one descriptor up by id, or null — config files name providers
/// by id, and an unknown name is a user error, not a crash.
ProviderDescriptor? descriptorById(String id) {
  for (final d in builtinDescriptors) {
    if (d.id == id) return d;
  }
  return null;
}
