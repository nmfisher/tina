import 'package:tina_console/tina_console.dart';
import 'package:tina_host/tina_host.dart';

/// Application commands that open a UI are handled by the submitting view.
Future<void>? offerSettingsCommand(
    SessionConnection session, String line, Future<void> Function()? open,
    {bool whileRunning = false}) {
  final decision = session.commandFor(line);
  if (decision == null ||
      decision.command.name != 'settings' ||
      open == null ||
      (whileRunning && !decision.command.allowWhileRunning)) return null;
  return open();
}

/// Offer a published command to the submitting attachment's presentation.
/// Runtime enablement stays authoritative: while a turn is running, a command
/// is offered only if it opts into running alongside work ([allowWhileRunning])
/// or its console handler opts into interactive presentation while running
/// ([OffersConsoleWhileRunning]).
Future<void>? offerConsoleCommand(SessionConnection session,
    Iterable<ConsoleAttachment> attachments, String line,
    {bool whileRunning = false}) {
  final decision = session.commandFor(line);
  if (decision == null) return null;
  for (final attachment in attachments) {
    final contribution = attachment.contribution;
    if (contribution is! ConsoleCommandHandler) continue;
    if (whileRunning &&
        !decision.command.allowWhileRunning &&
        contribution is! OffersConsoleWhileRunning) continue;
    final work = (contribution as ConsoleCommandHandler)
        .handleConsoleCommand(decision.command.name, decision.argument);
    if (work != null) return work;
  }
  return null;
}
