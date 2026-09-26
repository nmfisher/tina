/// The streaming provider seam: `tina_core`'s `LlmProvider` is the one
/// interface (it is re-exported by the barrel), plus the scripted provider
/// the tests play back. Real HTTP providers live outside this package.
library;

import 'dart:collection';

import 'package:tina_core/tina_core.dart';

import 'model.dart';

export 'package:tina_core/tina_core.dart' show LlmProvider, StreamEvent;

/// One scripted model reply, as the stream events the loop consumes: a
/// `ToolCallStart` per call, then the final `MessageComplete` carrying the
/// text and the tool-use blocks.
List<StreamEvent> scriptedReply(String text,
        {List<ToolUseBlock> calls = const []}) =>
    [
      for (final c in calls) ToolCallStart(id: c.id, name: c.name),
      MessageComplete(
          content: [if (text.isNotEmpty) TextBlock(text), ...calls],
          stopReason: calls.isEmpty ? 'end_turn' : 'tool_use'),
    ];

/// Plays back a queue of scripted event lists — one stream per request —
/// and records every request it saw. No network. Tests assert on the
/// recorded requests, which is how pairing, pinning, ordering, and
/// isolation get pinned.
final class ScriptedProvider implements LlmProvider {
  ScriptedProvider(List<List<StreamEvent>> script, {this.model = 'scripted'})
      : _script = Queue.of(script);

  @override
  final String model;

  final Queue<List<StreamEvent>> _script;
  final List<Request> requests = [];

  /// How many requests the provider received.
  int get callCount => requests.length;

  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) async* {
    requests.add(Request(
        systemPrompt: system,
        messages: List.of(messages),
        tools: List.of(tools)));
    if (_script.isEmpty) {
      // A test that scripted too few turns still gets a well-formed reply
      // so the loop can end cleanly instead of throwing.
      yield const TextDelta('(script exhausted)');
      yield const MessageComplete(
          content: [TextBlock('(script exhausted)')], stopReason: 'end_turn');
      return;
    }
    for (final event in _script.removeFirst()) {
      yield event;
    }
  }

  @override
  void close() {}
}
