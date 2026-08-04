import 'dart:async';

import 'package:tina_engine/tina_engine.dart';

/// Handler for [FakeTool]: receives the tool input, returns the result. May be
/// async (return `Future<ToolResult>`) — an async handler is how a test completes
/// a `cancelCompleter` mid-execution to exercise cancellation.
typedef FakeToolHandler = FutureOr<ToolResult> Function(
    Map<String, dynamic> input);

/// A minimal [Tool] fake with a configurable [handler]. The handler may be sync
/// or async; an async handler is how a test completes a `cancelCompleter`
/// mid-execution to exercise cancellation.
///
/// [execute] accepts [cancelSignal] and [onOutput] for signature conformance but
/// does not invoke them — the result comes solely from [handler]. Tests that need
/// to exercise the agent's streaming-output wiring should use a tool that calls
/// [onOutput] directly (see the `onOutput` test in `agent_test.dart`).
class FakeTool implements Tool {
  @override
  final ToolSchema schema;
  final FakeToolHandler handler;

  FakeTool(String name, this.handler)
      : schema = ToolSchema(
          name: name,
          description: 'fake $name',
          inputSchema: const {'type': 'object', 'properties': {}},
        );

  /// A fake tool that ignores its input and always returns [result].
  FakeTool.noOp(String name, {ToolResult result = const ToolResult('ok')})
      : this(name, (_) => result);

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async =>
      handler(input);
}
