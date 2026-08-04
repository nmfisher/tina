import '../gemini.dart';
import '../registry.dart';

/// Google Gemini — custom wire format
/// (`/v1beta/models/{model}:streamGenerateContent`). Auth via `x-goog-api-key`,
/// which is baked into [GeminiProvider]; the descriptor's [AuthScheme] only
/// selects the env var.
final ProviderDescriptor geminiDescriptor = ProviderDescriptor(
  id: 'gemini',
  name: 'Google Gemini',
  authSources: const [AuthSource('GEMINI_API_KEY', AuthScheme.apiKeyHeader)],
  defaultBaseUrl: 'https://generativelanguage.googleapis.com/v1beta',
  builder: (c) => GeminiProvider(
    apiKey: c.apiKey,
    model: c.model,
    baseUrl: c.baseUrl,
    maxTokens: c.maxTokens,
    streamIdleTimeout: c.streamIdleTimeout,
    requestTimeout: c.requestTimeout,
  ),
  models: const {
    'gemini-2.5-pro': ModelInfo(
        id: 'gemini-2.5-pro',
        name: 'Gemini 2.5 Pro',
        contextWindow: 1048576,
        maxOutput: 8192,
        supportsVision: true),
    'gemini-2.5-flash': ModelInfo(
        id: 'gemini-2.5-flash',
        name: 'Gemini 2.5 Flash',
        contextWindow: 1048576,
        maxOutput: 8192,
        supportsVision: true),
  },
);
