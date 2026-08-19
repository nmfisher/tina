import '../openai_compatible.dart';
import '../registry.dart';

/// Cerebras Inference — OpenAI-compatible.
///
/// Catalog verified against the public models endpoint
/// (https://api.cerebras.ai/public/v1/models) on 2026-08-15: the three live
/// models share a 131,072-token context window and a 40,960-token completion
/// cap. The fourth entry (`qwen3.8-27b`) is announced but not yet live — see
/// its comment for the provisional-specs rationale.
final ProviderDescriptor cerebrasDescriptor = ProviderDescriptor(
  id: 'cerebras',
  name: 'Cerebras',
  authSources: const [AuthSource('CEREBRAS_API_KEY', AuthScheme.bearerToken)],
  defaultBaseUrl: 'https://api.cerebras.ai/v1',
  builder: openAiCompatibleBuilder('Cerebras'),
  listsRemoteModels: true,
  models: const {
    // ANNOUNCED, NOT YET LIVE (added 2026-08-15). Cerebras announced this
    // model by email but the platform does not serve it yet —
    // GET /public/v1/models returns only the three models below, and the
    // per-model endpoint 404s for 'qwen3.8-27b'. Specs are PROVISIONAL:
    // the platform has published none, so this entry uses the platform's
    // uniform limits (131072 context / 40960 output) rather than the open
    // model's native 262144 context. The open-weights model ships a vision
    // encoder, but whether Cerebras will serve it is unknown — left false
    // so the agent loop never sends images to a text-only deployment.
    // Re-verify against /public/v1/models once the model goes live.
    'qwen3.8-27b': ModelInfo(
        id: 'qwen3.8-27b',
        name: 'Qwen3.8 27B',
        contextWindow: 131072,
        maxOutput: 40960),
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
