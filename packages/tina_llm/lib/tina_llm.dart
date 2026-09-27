/// tina_llm — one real provider over tina_core's `LlmProvider`: the
/// Anthropic-wire implementation with an injectable HTTP endpoint, SSE
/// parsing, exact-JSON request bodies (thinking signatures intact), and a
/// stall timeout. Plus the other wires (OpenAI-compatible, Gemini), the
/// sixteen built-in providers as data descriptors, and the models.dev
/// catalogue with its on-disk cache. No retries, no metering, no registry.
library;

export 'src/anthropic_provider.dart';
export 'src/builtin_descriptors.dart';
export 'src/descriptor.dart';
export 'src/gemini_provider.dart';
export 'src/http.dart';
export 'src/models_dev.dart';
export 'src/openai_compatible_provider.dart';
export 'src/request.dart';
export 'src/sse.dart';
export 'src/streaming.dart';
