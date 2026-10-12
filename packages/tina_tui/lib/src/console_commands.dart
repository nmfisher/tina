import 'package:tina_console/tina_console.dart';
import 'package:tina_host/tina_host.dart' show Commands;

import 'tui_commands.dart';

/// Application commands that open a UI are handled by the submitting view.
Future<void>? offerSettingsCommand(
    Commands commands, String line, Future<void> Function()? open,
    {bool whileRunning = false}) {
  final decision = dispatchLine(commands, line);
  if (decision is! RunCommand ||
      decision.command.name != 'settings' ||
      open == null ||
      (whileRunning && !decision.command.allowWhileRunning)) return null;
  return open();
}

/// Offer a published command to the submitting attachment's presentation.
/// Runtime enablement and its running-turn policy remain authoritative.
Future<void>? offerConsoleCommand(
    Commands commands, Iterable<ConsoleAttachment> attachments, String line,
    {bool whileRunning = false}) {
  final decision = dispatchLine(commands, line);
  if (decision is! RunCommand ||
      (whileRunning && !decision.command.allowWhileRunning)) return null;
  for (final attachment in attachments) {
    final contribution = attachment.contribution;
    if (contribution is! ConsoleCommandHandler) continue;
    final work = (contribution as ConsoleCommandHandler)
        .handleConsoleCommand(decision.command.name, decision.argument);
    if (work != null) return work;
  }
  return null;
}
