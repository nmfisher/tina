import 'package:tina_core/tina_core.dart';

/// Transient observations of execution, never a second transcript writer.
sealed class ToolActivity {
  const ToolActivity(this.call);
  final ToolUse call;
}

final class ToolStarted extends ToolActivity {
  const ToolStarted(super.call);
}

final class ToolOutput extends ToolActivity {
  const ToolOutput(super.call, this.text, {this.isError = false});
  final String text;
  final bool isError;
}

/// A replaceable status, separate from the tool's output text.
final class ToolProgress extends ToolActivity {
  const ToolProgress(super.call, this.status);
  final String status;
}

void _ignoreProgress(String status) {}

final class ToolFinished extends ToolActivity {
  const ToolFinished(super.call, this.result);
  final ToolResult result;
}

/// Per-call cancellation and output port. Executors own stopping their work;
/// the loop waits for cleanup before recording the result or starting a turn.
final class ToolExecutionContext {
  const ToolExecutionContext({
    required this.isCancelled,
    required this.whenCancelled,
    required this.report,
    this.progress = _ignoreProgress,
  });
  final void Function(String status) progress;
  final bool Function() isCancelled;
  final Future<void> whenCancelled;
  final void Function(String text, {bool isError}) report;
}

typedef ContextToolExecutor = Future<ToolResult> Function(
    Map<String, Object?> input, ToolExecutionContext context);
