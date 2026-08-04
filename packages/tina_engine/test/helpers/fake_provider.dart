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
/// copy-pasted across `repl_test.dart`, `session_test.dart`, and
/// `session_manager_test.dart`.
class FakeProvider extends LlmProvider {
  final List<List<StreamEvent>> responses;

  /// One record per [send] call, in call order.
  final List<({String system, List<Message> messages, List<ToolSchema> tools})>
      calls = [];

  int _index = 0;

  FakeProvider(this.responses, {String model = 'fake-model'}) : super(model);

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

/// A provider that blocks its stream until [gate] completes — for testing
/// concurrency/cancel without real I/O.
///
/// Controller-backed (not async*) so a subscription cancel returns promptly, the
/// way a real HTTP-backed stream would. When [gate] completes the provider
/// emits [releaseEvents] (default a single `MessageComplete` with text
/// "released").
///
/// For tests that need to observe subscription cancel directly, pass
/// [onCancel] and read [controller].
class HoldProvider extends LlmProvider {
  final Future<void>? gate;
  final void Function()? onCancel;
  final List<StreamEvent> releaseEvents;
  late final StreamController<StreamEvent> controller;

  HoldProvider({
    this.gate,
    this.onCancel,
    this.releaseEvents = const [
      MessageComplete(
        content: [TextBlock('released')],
        stopReason: 'end_turn',
      ),
    ],
    String model = 'hold',
  }) : super(model) {
    controller = StreamController<StreamEvent>(onCancel: onCancel);
    gate?.whenComplete(() {
      if (controller.isClosed || !controller.hasListener) return;
      for (final event in releaseEvents) {
        controller.add(event);
      }
      controller.close();
    });
  }

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) =>
      controller.stream;
}

/// A provider that captures the full message list each turn (for asserting a
/// reseeded leaf sees its prior history) and answers [answers.first].
class CaptureProvider extends LlmProvider {
  final List<List<Message>> captured;
  final List<String> answers;

  CaptureProvider(
    this.captured,
    this.answers, {
    String model = 'cap',
  }) : super(model);

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) {
    captured.add(List<Message>.from(messages));
    final answer = answers.first;
    return Stream.fromIterable([
      TextDelta(answer),
      MessageComplete(content: [TextBlock(answer)], stopReason: 'end_turn'),
    ]);
  }
}

/// A provider that forces the agent to keep calling a tool until a cap trips.
///
/// Each [send] emits one [ToolUseBlock] with an incrementing id. Configure
/// [toolName] and optional [usagePerTurn] to match the test scenario.
class LoopingProvider extends LlmProvider {
  final String toolName;
  final TokenUsage? usagePerTurn;
  int callCount = 0;

  LoopingProvider({
    this.toolName = 'loop',
    this.usagePerTurn,
    String model = 'looping',
  }) : super(model);

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) {
    callCount++;
    return Stream.fromIterable([
      MessageComplete(
        content: [
          ToolUseBlock(id: 'u$callCount', name: toolName, input: const {}),
        ],
        stopReason: 'tool_use',
        usage: usagePerTurn,
      ),
    ]);
  }
}
