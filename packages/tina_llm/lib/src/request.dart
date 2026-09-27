/// The request body, built from the transcript. This is the Anthropic
/// messages shape — the wire `api.z.ai/api/anthropic` speaks — with one
/// rule the tests pin exactly: a reasoning block goes back **with its
/// signature**, because a thinking block returned without one is rejected.
library;

import 'dart:convert';

import 'package:tina_core/tina_core.dart';

/// One tool, wire-shaped: `{name, description, input_schema}`.
Map<String, dynamic> _toolJson(ToolSchema t) => {
      'name': t.name,
      'description': t.description,
      'input_schema': t.inputSchema,
    };

/// One content block, wire-shaped. The core's JSON keys already match the
/// wire (the types were copied from it), so this is their `toJson` — with
/// reasoning handled separately because [ReasoningBlock] is transcript
/// data, not a `ContentBlock`.
Map<String, dynamic> _blockJson(ContentBlock b) => b.toJson();

/// One message, wire-shaped: `{role, content}`. Reasoning blocks ride
/// ahead of the answer content as `thinking` blocks, each with its
/// signature intact.
Map<String, dynamic> _messageJson(Message m) => {
      'role': m.role.name,
      'content': [
        for (final r in m.reasoning)
          {
            'type': 'thinking',
            'thinking': r.text,
            // The provider verifies this; absent means rejected. Kept
            // even when the block came from an old transcript without
            // one — the field is simply omitted there, as it arrived.
            if (r.signature != null) 'signature': r.signature,
          },
        for (final b in m.content) _blockJson(b),
      ],
    };

/// The full body for a messages call.
Map<String, dynamic> requestBody({
  required String model,
  required String system,
  required List<Message> messages,
  required List<ToolSchema> tools,
  int maxOutputTokens = 8192,
}) =>
    {
      'model': model,
      'max_tokens': maxOutputTokens,
      'stream': true,
      if (system.isNotEmpty) 'system': system,
      'messages': [for (final m in messages) _messageJson(m)],
      if (tools.isNotEmpty) 'tools': [for (final t in tools) _toolJson(t)],
    };

/// Encode the body once — the caller sends these bytes and counts them
/// for `content-length`.
List<int> encodeBody(Map<String, dynamic> body) =>
    utf8.encode(jsonEncode(body));
