import '../openai_compatible.dart';
import '../registry.dart';

/// GLM (Zhipu) — OpenAI-compatible on `/api/paas/v4` (note: `/v4`, not `/v1`;
/// the adapter's URL normalization tolerates it). A separate coding-plan
/// endpoint `/api/coding/paas/v4` is reachable via `--base-url`.
final ProviderDescriptor glmDescriptor = ProviderDescriptor(
  id: 'glm',
  name: 'GLM (Zhipu)',
  authSources: const [AuthSource('GLM_API_KEY', AuthScheme.bearerToken)],
  defaultBaseUrl: 'https://open.bigmodel.cn/api/paas/v4',
  builder: openAiCompatibleBuilder('GLM'),
  models: const {
    'glm-4.6': ModelInfo(
        id: 'glm-4.6',
        name: 'GLM-4.6',
        contextWindow: 131072,
        maxOutput: 8192),
    'glm-4.6v': ModelInfo(
        id: 'glm-4.6v',
        name: 'GLM-4.6V (vision)',
        contextWindow: 131072,
        maxOutput: 8192,
        supportsVision: true),
    'glm-5.2': ModelInfo(
        id: 'glm-5.2', name: 'GLM-5.2', contextWindow: 131072, maxOutput: 8192),
  },
);
