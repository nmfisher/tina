import '../anthropic.dart';
import '../registry.dart';

/// Anthropic — custom wire format (`/v1/messages`). Auth scheme is dynamic:
/// `ANTHROPIC_AUTH_TOKEN` → Bearer, `ANTHROPIC_API_KEY` → `x-api-key`. The
/// builder maps the registry-resolved [AuthScheme] onto [AnthropicProvider]'s
/// `useBearerAuth` flag.
final ProviderDescriptor anthropicDescriptor = ProviderDescriptor(
  id: 'anthropic',
  name: 'Anthropic',
  authSources: const [
    AuthSource('ANTHROPIC_AUTH_TOKEN', AuthScheme.bearerToken),
    AuthSource('ANTHROPIC_API_KEY', AuthScheme.apiKeyHeader),
  ],
  defaultBaseUrl: 'https://api.anthropic.com',
  builder: (c) => AnthropicProvider(
    apiKey: c.apiKey,
    useBearerAuth: c.authScheme == AuthScheme.bearerToken,
    model: c.model,
    baseUrl: c.baseUrl,
    maxTokens: c.maxTokens,
    streamIdleTimeout: c.streamIdleTimeout,
    requestTimeout: c.requestTimeout,
  ),
  // Catalog is illustrative — verify limits against Anthropic's docs before
  // relying on them for clamping.
  models: const {
    'claude-sonnet-4-6': ModelInfo(
      id: 'claude-sonnet-4-6',
      name: 'Claude Sonnet 4.6',
      contextWindow: 200000,
      maxOutput: 64000,
      supportsCaching: true,
    ),
  },
);
