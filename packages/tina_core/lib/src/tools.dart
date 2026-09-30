/// Tool value types, copied from `packages/tina_engine/lib/src/tools/tool.dart`
/// — same names, same members. The `Tool` base class, `ToolOutputCallback`,
/// `LocalControlTool`, `ToolRegistry` and the `ToolEvent` family are NOT
/// copied: they are runtime machinery, not value types, and the brief scopes
/// this package to the values a provider and a loop exchange.
library;

import 'message.dart';

/// A tool as advertised to the model.
class ToolSchema {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  /// Optional, channel-neutral description supplied by the tool's owner.
  /// Providers send only name/description/inputSchema to the model. The loop
  /// does not interpret this description or make decisions from it.
  final ToolDescription Function(Map<String, dynamic> input)? describe;
  const ToolSchema({
    required this.name,
    required this.description,
    required this.inputSchema,
    this.describe,
  });
}

/// Human-readable tool context, usable by a terminal, remote approval channel,
/// or other observer. It carries no rendering or permission policy.
final class ToolDescription {
  const ToolDescription(
      {required this.title, this.target = '', this.fields = const {}});
  final String title;
  final String target;
  final Map<String, String> fields;
  String get summary => target.isEmpty ? title : '$title · $target';
  Map<String, Object?> toJson() =>
      {'title': title, 'target': target, 'fields': fields};
  static ToolDescription? fromJson(Object? value) {
    if (value is! Map || value['title'] is! String) return null;
    final fields = value['fields'];
    return ToolDescription(
        title: value['title'] as String,
        target: value['target'] is String ? value['target'] as String : '',
        fields: {
          if (fields is Map)
            for (final entry in fields.entries)
              if (entry.key is String && entry.value is String)
                entry.key as String: entry.value as String
        });
  }
}

/// A tool call requested by the model. Derived from `ToolUseBlock`'s
/// member shape — no type of this name existed upstream; members and the
/// `argumentsParseError` semantics match the block exactly.
class ToolUse {
  final String id;
  final String name;
  final Map<String, dynamic> input;

  /// Set when the call's arguments were not valid JSON; [input] is then
  /// empty. See [ToolUseBlock.argumentsParseError].
  final String? argumentsParseError;
  const ToolUse({
    required this.id,
    required this.name,
    required this.input,
    this.argumentsParseError,
  });

  /// The transcript block carrying this call.
  ToolUseBlock toBlock() => ToolUseBlock(
        id: id,
        name: name,
        input: input,
        argumentsParseError: argumentsParseError,
      );

  factory ToolUse.fromBlock(ToolUseBlock block) => ToolUse(
        id: block.id,
        name: block.name,
        input: block.input,
        argumentsParseError: block.argumentsParseError,
      );
}

class ToolResult {
  final String content;
  final bool isError;

  /// Optional execution metadata. Null unless the tool measures it; purely
  /// informational today (no consumer reads these yet — they exist so a UI or
  /// guardrail leg can start without re-plumbing every tool). `bash` populates
  /// all three; other tools leave them null.
  final Duration? elapsed;

  /// True when the tool's own timeout fired and it killed the work.
  final bool? timedOut;

  /// True when the output channels carried zero characters (spilled output
  /// still counts — this reports the channels, not the visible tail).
  final bool? emptyOutput;
  const ToolResult(
    this.content, {
    this.isError = false,
    this.elapsed,
    this.timedOut,
    this.emptyOutput,
  });

  factory ToolResult.error(String message) =>
      ToolResult(message, isError: true);
}
