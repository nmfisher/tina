import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'goals.dart';

/// Runtime entry points are independent of CLI flags and process I/O.
final goalsOperations = <String, SessionOperationHandler>{
  'run': (plugin, arguments, context) async {
    final text = arguments['text'];
    final maxTurns = arguments['max_turns'];
    if (arguments.keys.any((key) => key != 'text' && key != 'max_turns') ||
        text is! String ||
        text.trim().isEmpty ||
        text.trim().length > goalMaxTextLength ||
        (maxTurns != null && (maxTurns is! int || maxTurns < 1))) {
      throw ArgumentError('Invalid goal or turn bound');
    }
    var cancelled = false;
    final achieved = await (plugin as GoalsPlugin).runToGoal(
      text: text,
      maxTurns: maxTurns as int?,
      cancel: context.cancellation,
      send: context.send,
      onTurn: (outcome) {
        if (context.cancelled) return;
        final reply = outcome.modelResponses.lastOrNull?.content
            .whereType<TextBlock>()
            .map((b) => b.text)
            .join();
        if (reply != null && reply.isNotEmpty) context.writeLine(reply);
        if (outcome.stopReason != StopReason.complete) {
          cancelled = outcome.stopReason == StopReason.cancelled;
          if (outcome.detail.isNotEmpty)
            context.writeLine(outcome.detail, error: true);
        }
      },
    );
    return SessionResult(
      stopReason: achieved
          ? StopReason.complete
          : cancelled || context.cancelled
              ? StopReason.cancelled
              : StopReason.error,
      detail: achieved || cancelled || context.cancelled
          ? ''
          : 'Goal was not achieved or completion could not be verified',
    );
  },
};
