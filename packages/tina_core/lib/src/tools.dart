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
  const ToolSchema({
    required this.name,
    required this.description,
    required this.inputSchema,
  });
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
