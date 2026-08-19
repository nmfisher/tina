import '../openai_compatible.dart';
import '../registry.dart';

/// QwenCloud — OpenAI-compatible.
///
/// Facts verified 2026-08-15:
/// - Base URL: the international DashScope compatible-mode endpoint
///   (https://dashscope-intl.aliyuncs.com/compatible-mode/v1) — QwenCloud's
///   default region (`ap-southeast-1`) per its own tooling
///   (github.com/qwencloud/qwencloud-ai, qwencloud_lib.py), live and serving.
///   Distinct from the `qwen` builtin, which targets the China endpoint.
/// - Auth: Bearer. `QWENCLOUD_API_KEY` is the tina-conventional name;
///   `DASHSCOPE_API_KEY` is accepted as a fallback because QwenCloud is the
///   DashScope console rebrand and its own scripts read that variable.
/// - Catalog: curated to the chat models; image/video/TTS/embedding models are
///   omitted because the OpenAI-compatible chat adapter cannot serve them.
///   Context windows from each model's live detail page
///   (https://www.qwencloud.com/models/<id>) — the platform currently
///   advertises 1M (1,048,576) for all of them, superseding the older
///   128K/256K figures in qwencloud-ai's April snapshot. maxOutput is not
///   published per model; 8192 is the DashScope default output cap.
final ProviderDescriptor qwencloudDescriptor = ProviderDescriptor(
  id: 'qwencloud',
  name: 'QwenCloud',
  authSources: const [
    AuthSource('QWENCLOUD_API_KEY', AuthScheme.bearerToken),
    AuthSource('DASHSCOPE_API_KEY', AuthScheme.bearerToken),
  ],
  defaultBaseUrl: 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',
  builder: openAiCompatibleBuilder('QwenCloud'),
  listsRemoteModels: true,
  models: const {
    'qwen3.8-max': ModelInfo(
        id: 'qwen3.8-max',
        name: 'Qwen3.8 Max',
        contextWindow: 1048576,
        maxOutput: 8192),
    'qwen3.7-plus': ModelInfo(
        id: 'qwen3.7-plus',
        name: 'Qwen3.7 Plus',
        contextWindow: 1048576,
        maxOutput: 8192,
        supportsVision: true),
    'qwen3.6-plus': ModelInfo(
        id: 'qwen3.6-plus',
        name: 'Qwen3.6 Plus',
        contextWindow: 1048576,
        maxOutput: 8192,
        supportsVision: true),
    'qwen3.5-plus': ModelInfo(
        id: 'qwen3.5-plus',
        name: 'Qwen3.5 Plus',
        contextWindow: 1048576,
        maxOutput: 8192,
        supportsVision: true),
    'qwen3-max': ModelInfo(
        id: 'qwen3-max',
        name: 'Qwen3 Max',
        contextWindow: 1048576,
        maxOutput: 8192),
    'qwen-plus': ModelInfo(
        id: 'qwen-plus',
        name: 'Qwen Plus',
        contextWindow: 1048576,
        maxOutput: 8192),
    'qwen-flash': ModelInfo(
        id: 'qwen-flash',
        name: 'Qwen Flash',
        contextWindow: 1048576,
        maxOutput: 8192),
    'qwen-turbo': ModelInfo(
        id: 'qwen-turbo',
        name: 'Qwen Turbo',
        contextWindow: 1048576,
        maxOutput: 8192),
    'qwq-plus': ModelInfo(
        id: 'qwq-plus',
        name: 'QwQ Plus',
        contextWindow: 1048576,
        maxOutput: 8192),
    'qwen3-coder-plus': ModelInfo(
        id: 'qwen3-coder-plus',
        name: 'Qwen3 Coder Plus',
        contextWindow: 1048576,
        maxOutput: 8192),
    'qwen3-coder-next': ModelInfo(
        id: 'qwen3-coder-next',
        name: 'Qwen3 Coder Next',
        contextWindow: 1048576,
        maxOutput: 8192),
    'qwen3-vl-plus': ModelInfo(
        id: 'qwen3-vl-plus',
        name: 'Qwen3 VL Plus',
        contextWindow: 1048576,
        maxOutput: 8192,
        supportsVision: true),
  },
);
