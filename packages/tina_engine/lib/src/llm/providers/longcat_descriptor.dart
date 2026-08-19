import '../openai_compatible.dart';
import '../registry.dart';

/// LongCat — Meituan's long-context reasoning model, OpenAI-compatible.
///
/// Published on models.dev as `meituan/longcat-2.0`; the overlay alias
/// maps `longcat` → `meituan` so models.dev auto-discovers new models.
final ProviderDescriptor longcatDescriptor = ProviderDescriptor(
  id: 'longcat',
  name: 'LongCat',
  authSources: const [AuthSource('LONGCAT_API_KEY', AuthScheme.bearerToken)],
  defaultBaseUrl: 'https://api.longcat.chat',
  builder: openAiCompatibleBuilder('LongCat'),
  listsRemoteModels: true,
  models: const {
    'longcat-2.0': ModelInfo(
      id: 'longcat-2.0',
      name: 'LongCat-2.0',
      contextWindow: 1000000,
      maxOutput: 131072,
      supportsVision: false,
    ),
  },
);
