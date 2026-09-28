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
  });
  final bool Function() isCancelled;
  final Future<void> whenCancelled;
  final void Function(String text, {bool isError}) report;
}

typedef ContextToolExecutor = Future<ToolResult> Function(
    Map<String, Object?> input, ToolExecutionContext context);
