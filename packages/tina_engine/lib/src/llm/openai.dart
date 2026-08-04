import 'openai_compatible.dart';

/// The built-in OpenAI provider — a thin named wrapper around
/// [OpenAiCompatibleAdapter]. The OpenAI descriptor builds an adapter directly
/// via [openAiCompatibleBuilder]; this subclass exists for call sites that
/// construct a provider by concrete type.
class OpenAiProvider extends OpenAiCompatibleAdapter {
  OpenAiProvider({
    required super.apiKey,
    required super.model,
    super.maxTokens,
    super.baseUrl,
    super.streamIdleTimeout,
    super.client,
  });
}
