/// The model-provider interface, copied from
/// `packages/tina_engine/lib/src/llm/provider.dart` — same signature, same
/// members, with one deliberate difference: `model` is immutable here (see
/// below). The event and usage types it streams live in `stream.dart`.
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
