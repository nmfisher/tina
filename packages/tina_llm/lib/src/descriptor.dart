/// A provider as data: identity, base URL, which wire it speaks, the
/// environment variable holding its key, and the model list it serves
/// when the catalogue has nothing to add. One descriptor per provider;
/// one wire implementation per wire — never a class per vendor.
///
/// Deliberately left behind from the old engine: the `builder` closure
/// (construction moves to a top-level factory on [ProviderWires]), the
/// `AuthScheme` enum (every provider here is either a bearer token or a
/// header key — [keyStyle] says which), `authSources` as a list (one
/// source each; a fallback chain is policy, not identity), and the
/// registry service object that held these.
library;

import 'package:tina_core/tina_core.dart';

import 'anthropic_provider.dart';
import 'gemini_provider.dart';
import 'openai_compatible_provider.dart';

/// Which wire implementation a descriptor's turns travel on.
enum ProviderWire {
  /// Anthropic `/v1/messages` — [AnthropicProvider].
  anthropic,

  /// OpenAI `/chat/completions` and its many clones —
  /// [OpenAiCompatibleProvider].
  openAiCompatible,

  /// Google `streamGenerateContent` — [GeminiProvider].
  gemini,
}

/// How the key travels: bearer header or a named key header. Nothing
/// else exists on the wires tina speaks.
enum ProviderKeyStyle { bearer, header }

/// A model a provider serves, as the descriptor states it: the floor the
/// models.dev catalogue can correct, and the fallback when the catalogue
/// is absent or stale. Shape identical to the catalogue's model records.
class ModelInfo {
  final String id;
  final String name;

  /// Input context the descriptor promises, in tokens.
  final int contextWindow;

  /// Output ceiling the descriptor promises, in tokens; null when the
  /// provider publishes none.
  final int? maxOutput;
  final bool supportsTools;
  final bool supportsVision;
  const ModelInfo({
    required this.id,
    required this.name,
    required this.contextWindow,
    this.maxOutput,
    this.supportsTools = false,
    this.supportsVision = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'context_window': contextWindow,
        if (maxOutput != null) 'max_output': maxOutput,
        'supports_tools': supportsTools,
        'supports_vision': supportsVision,
      };

  static ModelInfo fromJson(Map<String, dynamic> j) => ModelInfo(
        id: j['id'] as String,
        name: j['name'] as String? ?? j['id'] as String,
        contextWindow: (j['context_window'] as num?)?.toInt() ?? 131072,
        maxOutput: (j['max_output'] as num?)?.toInt(),
        supportsTools: j['supports_tools'] == true,
        supportsVision: j['supports_vision'] == true,
      );
}

/// One provider descriptor. See the library comment for what was
/// deliberately left behind.
class ProviderDescriptor {
  /// Stable id: what config files and `--provider` spell.
  final String id;

  /// Human name.
  final String name;

  /// Which wire implementation serves the turns.
  final ProviderWire wire;

  /// The base URL every request path is resolved against.
  final String baseUrl;

  /// The environment variable holding the key, read at runtime only.
  final String keyEnvVar;

  /// How the key travels on the wire.
  final ProviderKeyStyle keyStyle;

  /// The models the provider is known to serve, as a floor for the
  /// catalogue. Keys are model ids.
  final Map<String, ModelInfo> models;

  const ProviderDescriptor({
    required this.id,
    required this.name,
    required this.wire,
    required this.baseUrl,
    required this.keyEnvVar,
    required this.keyStyle,
    this.models = const {},
  });

  /// Construct the wire provider for [model]. The token closure is
  /// required — production passes one reading [keyEnvVar] from the
  /// environment; tests pass a literal without touching any store.
  LlmProvider build({
    required String model,
    required String Function() tokenFrom,
    HttpEndpoint? endpoint,
  }) {
    final endpoint0 = endpoint ?? IoHttpEndpoint(endpoint: baseUrl);
    return switch (wire) {
      ProviderWire.anthropic => AnthropicProvider(
          model: model,
          endpoint: endpoint0,
          tokenFrom: tokenFrom,
        ),
      ProviderWire.openAiCompatible => OpenAiCompatibleProvider(
          model: model,
          baseUrl: baseUrl,
          endpoint: endpoint0,
          tokenFrom: tokenFrom,
        ),
      ProviderWire.gemini => GeminiProvider(
          model: model,
          baseUrl: baseUrl,
          endpoint: endpoint0,
          tokenFrom: tokenFrom,
        ),
    };
  }

  /// The descriptor's own model list, order-stable.
  List<ModelInfo> get modelList => models.values.toList(growable: false);
}
