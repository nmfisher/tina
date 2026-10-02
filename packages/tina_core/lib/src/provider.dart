/// The model-provider interface. The provider's model is immutable; stream
/// event and usage types live in `stream.dart`.
library;

import 'message.dart';
import 'stream.dart';
import 'tools.dart';

abstract class LlmProvider {
  /// The model this provider serves. The provider never changes it;
  /// choosing or switching providers is the loop's job.
  final String model;
  LlmProvider(this.model);

  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  });

  void close() {}
}

/// A named JSON Schema for a model's final answer. Separate from tool schemas:
/// a structured request produces data and cannot invoke tools.
final class JsonOutputSchema {
  const JsonOutputSchema({required this.name, required this.schema});
  final String name;
  final Map<String, Object?> schema;
}

/// Optional provider capability, independent of the agent loop. Adapters request
/// schema-constrained output where supported, or JSON mode on endpoints which
/// only support JSON syntax. Callers must validate the completed answer either
/// way; refusals, truncation and incompatible endpoints remain possible.
abstract interface class StructuredOutputProvider {
  Stream<StreamEvent> sendStructured({
    required String system,
    required List<Message> messages,
    required JsonOutputSchema output,
  });
}
