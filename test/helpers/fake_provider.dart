import 'dart:async';

import 'package:tina_engine/tina_engine.dart';

/// A scriptable [LlmProvider] for unit tests.
///
/// Replays one entry from [responses] per [send] call, in order, and records
/// every call in [calls] so tests can assert on the system prompt, message
/// history, and tool schemas the agent sent. If the agent makes more calls than
/// [responses] has entries, the extra calls yield an empty stream (the agent's
/// stream consumer then surfaces "stream ended without a complete response").
///
/// This deduplicates the inline `_DoneProvider` / `_FakeProvider` fakes that were
/// copy-pasted across `session_test.dart`, `session_manager_test.dart`,
/// `session_controller_test.dart`, `tui_coordinator_test.dart`, and
/// `session_commands/session_command_handlers_test.dart`.
class FakeProvider extends LlmProvider {
  final List<List<StreamEvent>> responses;

  /// One record per [send] call, in call order.
  final List<({String system, List<Message> messages, List<ToolSchema> tools})>
      calls = [];

  int _index = 0;

  FakeProvider(this.responses, {String model = 'fake-model'}) : super(model);

  /// A provider that always returns a single `ok` completion.
  ///
  /// Replaces the copy-pasted `_FakeProvider` class.
  FakeProvider.always({String model = 'fake-model'})
      : this(const [
          [
            MessageComplete(
              content: [TextBlock('ok')],
              stopReason: 'end_turn',
            ),
          ],
        ], model: model);

  /// A provider that immediately returns a single `ok` completion.
  ///
  /// Convenience alias for the common "done" fake used across tests.
  FakeProvider.done({String model = 'done'}) : this.always(model: model);

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    calls.add((system: system, messages: messages, tools: tools));
    if (_index < responses.length) {
      for (final event in responses[_index++]) {
        yield event;
      }
    }
  }
}
