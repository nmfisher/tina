/// Server-sent events → `tina_core` stream events, one frame at a time.
///
/// An SSE stream is a sequence of lines; a frame is the lines since the
/// last blank line. Anthropic's frames are `event: <name>` plus one
/// `data: <json>`; the event name is redundant (the JSON carries `type`),
/// so this parses the data payloads and maps each type. A malformed frame
/// is reported through [SseParser.onBadFrame] — never thrown past the
/// provider.
library;

import 'dart:convert';

import 'package:tina_core/tina_core.dart';

/// Accumulates bytes, splits them into SSE frames, and hands each data
/// payload to [onFrame] as it completes. Feed chunks as they arrive; call
/// [finish] at end-of-body so a trailing frame without its blank line is
/// still delivered.
final class SseParser {
  final void Function(Map<String, dynamic> data) onFrame;

  /// Called for a frame whose data is not valid JSON or not an object.
  /// The parser keeps going either way; the callback decides what to do.
  final void Function(String problem)? onBadFrame;

  String _buffer = '';

  SseParser({required this.onFrame, this.onBadFrame});

  /// Feed one chunk of bytes. Partial UTF-8 sequences across chunk
  /// boundaries are handled by the decoder; the line buffer holds the rest.
  void add(List<int> chunk) {
    _buffer += utf8.decode(chunk, allowMalformed: true);
    _drain(finalDrain: false);
  }

  /// End of body: flush any final complete frame.
  void finish() => _drain(finalDrain: true);

  void _drain({required bool finalDrain}) {
    // Frames separate on a blank line. Accept \n\n and \r\n\r\n.
    final pattern = RegExp(r'\r?\n\r?\n');
    while (true) {
      final m = pattern.firstMatch(_buffer);
      if (m == null) break;
      final frame = _buffer.substring(0, m.start);
      _buffer = _buffer.substring(m.end);
      _dispatch(frame);
    }
    if (finalDrain && _buffer.trim().isNotEmpty) {
      _dispatch(_buffer);
      _buffer = '';
    }
  }

  void _dispatch(String frame) {
    // One data payload per frame; Anthropic never splits JSON across
    // `data:` lines. Multiple `data:` lines are joined the SSE way anyway.
    final dataLines = <String>[];
    for (final line in frame.split(RegExp(r'\r?\n'))) {
      if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trimLeft());
      }
      // `event:`, `id:`, comments, anything else: ignored — the JSON's
      // own `type` field is the truth.
    }
    if (dataLines.isEmpty) return;
    final payload = dataLines.join('\n');
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) {
        onFrame(decoded);
      } else {
        onBadFrame
            ?.call('frame data was ${decoded.runtimeType}, not an object');
      }
    } on FormatException catch (e) {
      onBadFrame?.call('frame JSON did not parse: ${e.message}');
    }
  }
}

/// What the provider must remember across the frames of one response, so
/// the final [MessageComplete] can carry the blocks, the stop reason, and
/// the usage in one place. Text and reasoning deltas stream straight
/// through; the completion is assembled at `message_stop`.
final class ResponseBuilder {
  final List<ContentBlock> content = [];

  /// Accumulated answer text (the `text_delta` events, so far).
  final StringBuffer text = StringBuffer();

  /// Accumulated reasoning text and its signature.
  final StringBuffer thinking = StringBuffer();
  String? signature;
  bool reasoningObserved = false;

  /// Tool arguments arrive as partial JSON across `input_json_delta`
  /// frames; keyed by the tool call's index in the stream.
  final Map<int, StringBuffer> toolJson = {};
  final Map<int, ({String id, String name})> toolMeta = {};

  /// From `message_delta`.
  String? stopReason;
  TokenUsage? usage;

  /// A malformed or failed frame's first complaint, to carry as a stream
  /// error if the body never completes.
  String? badFrame;

  /// True once an error frame was seen: the response ended in the
  /// provider's eyes, and no completion may be fabricated after it.
  bool errored = false;

  /// The completion, once `message_stop` (or end of stream) arrives.
  MessageComplete? build() {
    // Tool inputs: parse the accumulated argument JSON. Unparseable
    // arguments become an empty input with the parse error recorded —
    // the same shape the core uses for that case.
    for (final entry in toolJson.entries) {
      final meta = toolMeta[entry.key];
      if (meta == null) continue;
      Map<String, dynamic> input = {};
      String? parseError;
      try {
        final decoded = jsonDecode(entry.value.toString());
        if (decoded is Map<String, dynamic>) {
          input = decoded;
        } else {
          parseError = 'tool arguments were ${decoded.runtimeType}';
        }
      } on FormatException catch (e) {
        parseError = e.message;
      }
      content.add(ToolUseBlock(
        id: meta.id,
        name: meta.name,
        input: input,
        argumentsParseError: parseError,
      ));
    }
    final blocks = <ContentBlock>[
      if (text.isNotEmpty) TextBlock(text.toString()),
      ...content,
    ];
    return MessageComplete(
      content: blocks,
      stopReason: stopReason ?? 'end_turn',
      usage: usage,
      diagnostics: CompletionDiagnostics(
        reasoningObserved: reasoningObserved,
        reasoningTokens: null,
      ),
    );
  }
}

/// Map one parsed frame onto [events] and the [builder] state. Returns
/// true when the response is over (`message_stop` seen). Unknown frame
/// types are ignored, not fatal: providers add types. The ping frame is a
/// keep-alive and produces nothing.
bool applyFrame(Map<String, dynamic> frame, ResponseBuilder builder,
    List<StreamEvent> events) {
  switch (frame['type'] as String?) {
    case 'ping':
    case 'message_start': // usage totals come later, in message_delta
      break;

    case 'content_block_start':
      final block = frame['content_block'] as Map<String, dynamic>?;
      final index = (frame['index'] as num?)?.toInt() ?? 0;
      switch (block?['type'] as String?) {
        case 'tool_use':
          final meta = (
            id: block!['id'] as String,
            name: block['name'] as String,
          );
          builder.toolMeta[index] = meta;
          builder.toolJson[index] = StringBuffer();
          events.add(ToolCallStart(
            id: meta.id,
            name: meta.name,
          ));
        case 'thinking':
          builder.reasoningObserved = true;
          events.add(const ReasoningDelta('', startsBlock: true));
      }

    case 'content_block_delta':
      final delta = frame['delta'] as Map<String, dynamic>?;
      final index = (frame['index'] as num?)?.toInt() ?? 0;
      switch (delta?['type'] as String?) {
        case 'text_delta':
          final t = delta!['text'] as String;
          builder.text.write(t);
          events.add(TextDelta(t));
        case 'thinking_delta':
          // The wire keys thinking text as `thinking`.
          final t = delta!['thinking'] as String;
          builder.thinking.write(t);
          events.add(ReasoningDelta(t));
        case 'signature_delta':
          // The signature over the just-closed thinking block; travels on
          // ReasoningEnd so the stored block can be sent back intact.
          builder.signature = delta!['signature'] as String;
          events.add(ReasoningEnd(signature: builder.signature));
        case 'input_json_delta':
          // Tool arguments arrive as partial JSON; parse at close.
          builder.toolJson[index]?.write(delta!['partial_json'] as String? ?? '');
      }

    case 'message_delta':
      final delta = frame['delta'] as Map<String, dynamic>?;
      final usage = frame['usage'] as Map<String, dynamic>?;
      builder.stopReason = delta?['stop_reason'] as String? ?? builder.stopReason;
      if (usage != null) {
        builder.usage = TokenUsage(
          inputTokens: (usage['input_tokens'] as num?)?.toInt() ?? 0,
          outputTokens: (usage['output_tokens'] as num?)?.toInt() ?? 0,
          cacheCreationInputTokens:
              (usage['cache_creation_input_tokens'] as num?)?.toInt() ?? 0,
          cacheReadInputTokens:
              (usage['cache_read_input_tokens'] as num?)?.toInt() ?? 0,
        );
      }

    case 'message_stop':
      return true;

    case 'error':
      final err = frame['error'] as Map<String, dynamic>?;
      events.add(StreamError(
        err?['message'] as String? ?? 'provider sent an error frame',
        providerCode: err?['type'] as String?,
      ));
      // The response is over: no completion is fabricated after an error.
      builder.errored = true;
      return true;
  }
  return false;
}
