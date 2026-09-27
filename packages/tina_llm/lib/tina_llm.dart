/// tina_llm — one real provider over tina_core's `LlmProvider`: the
/// Anthropic-wire implementation with an injectable HTTP endpoint, SSE
/// parsing, exact-JSON request bodies (thinking signatures intact), and a
/// stall timeout. No retries, no metering, no registry.
library;

export 'src/anthropic_provider.dart';
export 'src/http.dart';
export 'src/request.dart';
export 'src/sse.dart';
