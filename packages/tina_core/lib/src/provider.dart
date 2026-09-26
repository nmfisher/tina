/// The model-provider interface, copied verbatim from
/// `packages/tina_engine/lib/src/llm/provider.dart` — same signature, same
/// members. The event and usage types it streams live in `stream.dart`.
library;

import 'message.dart';
import 'stream.dart';
import 'tools.dart';

abstract class LlmProvider {
  /// Mutable so `/model <name>` can switch the active model mid-session.
  String model;
  LlmProvider(this.model);

  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  });

  void close() {}
}
