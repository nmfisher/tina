import '../anthropic.dart';
import '../registry.dart';

/// Tencent Cloud MaaS — Anthropic-compatible endpoint.
///
/// Example config:
/// ```toml
/// [providers.tencent]
/// api_key = "YOUR_API_KEY"
/// ```
///
/// The service expects the Anthropic Messages API wire format and a bearer
/// token, so this descriptor reuses [AnthropicProvider] with [useBearerAuth].
final ProviderDescriptor tencentDescriptor = ProviderDescriptor(
  id: 'tencent',
  name: 'Tencent Cloud MaaS',
  authSources: const [
    AuthSource('TENCENT_AUTH_TOKEN', AuthScheme.bearerToken),
    AuthSource('TENCENT_API_KEY', AuthScheme.apiKeyHeader),
  ],
  defaultBaseUrl: 'https://tokenhub-intl.tencentcloudmaas.com',
  builder: (c) => AnthropicProvider(
    apiKey: c.apiKey,
    useBearerAuth: c.authScheme == AuthScheme.bearerToken,
    model: c.model,
    baseUrl: c.baseUrl,
    maxTokens: c.maxTokens,
    streamIdleTimeout: c.streamIdleTimeout,
    requestTimeout: c.requestTimeout,
  ),
  models: const {
    'hy3': ModelInfo(
      id: 'hy3',
      name: 'Hy3',
      contextWindow: 256000,
      maxOutput: 64000,
    ),
    'deepseek-v4-pro': ModelInfo(
      id: 'deepseek-v4-pro',
      name: 'DeepSeek V4 Pro',
      contextWindow: 256000,
      maxOutput: 8192,
    ),
  },
);
