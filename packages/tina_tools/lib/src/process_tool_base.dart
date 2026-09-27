import 'package:tina_core/tina_core.dart';

import 'process_runner.dart';
import 'tool.dart';
import 'tool_input.dart';

/// Shared plumbing for the two process tools: validate input, run one
/// request through the runner, and translate the outcome into a tool result.
///
/// The translation is the whole contract with the model: a
/// [CommandRefused] becomes an **ordinary error result carrying the reason**
/// — exactly how the file tools surface a `SandboxViolation` — so the model
/// reads why it was refused as the tool result for that call. A
/// [CommandBlocked] (the OS sandbox stopped a command the gate approved)
/// becomes an error result too, but names the sandbox as the stopper: the
/// model must not read it as an ordinary failure and retry the same thing.
/// A completed run is reported even when the exit code is non-zero: a
/// failing command is a normal result, not a refusal, and the two must not
/// be confused.
abstract class ProcessToolBase implements Tool {
  /// The runner this tool starts processes through. Enforcement (mode,
  /// writable directories, approver, grants, the OS jail) lives on the
  /// runner; the tool has none.
  ProcessRunner get runner;

  Duration get defaultTimeout => const Duration(minutes: 10);

  /// Run one request and shape the outcome for the model.
  Future<ToolResult> runRequest(ProcessRequest request) async {
    final outcome = await runner.run(request);
    return switch (outcome) {
      CommandRefused(:final reason) => ToolResult.error(reason),
      CommandBlocked(:final reason) => ToolResult.error(reason),
      CommandCompleted(:final exitCode, :final stdout, :final stderr) =>
        ToolResult(_report(exitCode, stdout, stderr),
            elapsed: null, timedOut: exitCode == -9, emptyOutput: false),
    };
  }

  String _report(int exitCode, String stdout, String stderr) {
    final buf = StringBuffer('exit code: $exitCode');
    if (stdout.trim().isNotEmpty) {
      buf.write('\n--- stdout ---${stdout.trim()}');
    }
    if (stderr.trim().isNotEmpty) {
      buf.write('\n--- stderr ---${stderr.trim()}');
    }
    return buf.toString();
  }

  /// Shared input validation: an optional timeout in seconds.
  Duration? timeoutFrom(Map<String, dynamic> input) {
    final secs = optionalInt(input, 'timeout');
    return secs == null ? null : Duration(seconds: secs);
  }
}
