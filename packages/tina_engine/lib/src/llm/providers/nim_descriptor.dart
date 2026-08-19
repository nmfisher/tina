import '../openai_compatible.dart';
import '../registry.dart';

/// NVIDIA NIM — OpenAI-compatible hosted inference at `integrate.api.nvidia.com`.
/// Serves 80+ models (Llama, Nemotron, DeepSeek, Qwen, Mistral, Kimi, …) behind
/// a single `/v1/chat/completions` endpoint with Bearer `nvapi-*` auth.
final ProviderDescriptor nimDescriptor = ProviderDescriptor(
  id: 'nim',
  name: 'NVIDIA NIM',
  authSources: const [AuthSource('NVIDIA_API_KEY', AuthScheme.bearerToken)],
  defaultBaseUrl: 'https://integrate.api.nvidia.com',
  builder: openAiCompatibleBuilder('NVIDIA NIM'),
  listsRemoteModels: true,
  models: const {
    'meta/llama-3.3-70b-instruct': ModelInfo(
      id: 'meta/llama-3.3-70b-instruct',
      name: 'Llama 3.3 70B',
      contextWindow: 131072,
      maxOutput: 4096,
    ),
    'meta/llama-3.1-70b-instruct': ModelInfo(
      id: 'meta/llama-3.1-70b-instruct',
      name: 'Llama 3.1 70B',
      contextWindow: 131072,
      maxOutput: 4096,
    ),
    'meta/llama-3.1-8b-instruct': ModelInfo(
      id: 'meta/llama-3.1-8b-instruct',
      name: 'Llama 3.1 8B',
      contextWindow: 131072,
      maxOutput: 4096,
    ),
    'google/gemma-4-31b-it': ModelInfo(
      id: 'google/gemma-4-31b-it',
      name: 'Gemma 4 31B IT',
      // Dense 31B reasoning model (frontier reasoning for coding/agentic
      // workflows). Natively supports function calling + multimodal input.
      // NIM's hosted endpoint accepts the OpenAI `tools` array and applies the
      // Gemma 4 chat template server-side, so the OpenAI-compatible adapter
      // drives it with no special handling. `max_tokens` tops out at 32768 per
      // the NIM API ref; 128K context is the native window.
      //
      // Thinking is OFF by default (matches upstream Gemma 4). Enabling it is
      // now a one-liner via [extraBody]:
      //   extraBody: {'chat_template_kwargs': {'enable_thinking': true}}
      // Left off because NIM serves via vLLM, whose Gemma4ReasoningParser has a
      // known bug (vllm-project/vllm#38855) that leaks raw `<think>` tags into
      // `content` instead of routing them to `reasoning_content` — so enabling
      // it blind would dump reasoning into the response. Flip it once that's
      // verified fixed and we've confirmed the stream stays clean.
      contextWindow: 131072,
      maxOutput: 32768,
      supportsVision: true,
    ),
    'google/diffusiongemma-26b-a4b-it': ModelInfo(
      id: 'google/diffusiongemma-26b-a4b-it',
      name: 'DiffusionGemma 26B A4B IT',
      contextWindow: 32768,
      maxOutput: 4096,
      supportsTools: false,
    ),
    'deepseek-ai/deepseek-v4-pro': ModelInfo(
      id: 'deepseek-ai/deepseek-v4-pro',
      name: 'DeepSeek V4 Pro',
      contextWindow: 131072,
      maxOutput: 8192,
    ),
    'nvidia/llama-3.1-nemotron-ultra-253b-v1': ModelInfo(
      id: 'nvidia/llama-3.1-nemotron-ultra-253b-v1',
      name: 'Nemotron Ultra 253B',
      contextWindow: 131072,
      maxOutput: 4096,
    ),
    'nvidia/llama-3.3-nemotron-super-49b-v1.5': ModelInfo(
      id: 'nvidia/llama-3.3-nemotron-super-49b-v1.5',
      name: 'Nemotron Super 49B v1.5',
      contextWindow: 131072,
      maxOutput: 4096,
    ),
    'mistralai/mistral-nemotron': ModelInfo(
      id: 'mistralai/mistral-nemotron',
      name: 'Mistral Nemotron',
      contextWindow: 131072,
      maxOutput: 4096,
    ),
    'qwen/qwen3-coder-480b-a35b-instruct': ModelInfo(
      id: 'qwen/qwen3-coder-480b-a35b-instruct',
      name: 'Qwen3 Coder 480B',
      contextWindow: 131072,
      maxOutput: 8192,
    ),
    'qwen/qwq-32b': ModelInfo(
      id: 'qwen/qwq-32b',
      name: 'QwQ 32B (reasoning)',
      contextWindow: 131072,
      maxOutput: 8192,
      supportsTools: false,
    ),
    'moonshotai/kimi-k2-instruct': ModelInfo(
      id: 'moonshotai/kimi-k2-instruct',
      name: 'Kimi K2',
      contextWindow: 131072,
      maxOutput: 8192,
    ),
  },
);
