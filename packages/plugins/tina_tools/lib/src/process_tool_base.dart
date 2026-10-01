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

  @override
  Future<ToolResult> execute(Map<String, dynamic> input,
      {ProcessControl? control});

  Duration get defaultTimeout => const Duration(minutes: 10);

  /// Run one request and shape the outcome for the model.
  Future<ToolResult> runRequest(ProcessRequest request,
      {ProcessControl? control, Map<String, dynamic> input = const {}}) async {
    bool network;
    bool background;
    String reason;
    try {
      network = optionalBool(input, 'network') ?? false;
      background = optionalBool(input, 'background') ?? false;
      reason = network ? requiredString(input, 'network_reason') : '';
    } on ToolValidationException catch (e) {
      return ToolResult.error(e.message);
    }
    // Declare requirements; the runner reviews the whole invocation once.
    control = (control ?? const ProcessControl()).copyWith(
      networkRequested: network,
      networkReason: reason,
      networkAllowed: false,
      background: background,
    );
    final watch = Stopwatch()..start();
    final outcome = await runner.run(request, control: control);
    watch.stop();
    return processOutcomeResult(outcome, elapsed: watch.elapsed);
  }

  /// Shared input validation: an optional timeout in seconds.
  Duration? timeoutFrom(Map<String, dynamic> input) {
    final secs = optionalInt(input, 'timeout');
    return secs == null ? null : Duration(seconds: secs);
  }
}

ToolResult processOutcomeResult(RunOutcome outcome, {Duration? elapsed}) {
  return switch (outcome) {
    CommandRunning(:final id, :final output) => ToolResult(
        'Process is still running. Job ID: $id. Use process with job_id and '
        'action status/wait/cancel; do not restart this command.\n$output',
        elapsed: elapsed),
    CommandRefused(:final reason) => ToolResult.error(reason),
    CommandBlocked(:final reason) => ToolResult.error(reason),
    CommandCompleted(
      :final exitCode,
      :final stdout,
      :final stderr,
      :final cancelled,
      :final timedOut
    ) =>
      ToolResult(_report(exitCode, stdout, stderr),
          isError: exitCode != 0 || cancelled || timedOut,
          elapsed: elapsed,
          timedOut: timedOut,
          emptyOutput: stdout.isEmpty && stderr.isEmpty),
  };
}

String _report(int exitCode, String stdout, String stderr) {
  final buf = StringBuffer('exit code: $exitCode');
  if (stdout.trim().isNotEmpty) {
    buf.write('\n--- stdout ---\n${stdout.trim()}');
  }
  if (stderr.trim().isNotEmpty) {
    buf.write('\n--- stderr ---\n${stderr.trim()}');
  }
  return buf.toString();
}
