import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'goals.dart';

const goalOption = CliOption('goal',
    description:
        'Run without the TUI until the goal judge reports success; - reads stdin.',
    valueName: 'TEXT|-',
    validate: _validateGoal);
const maxGoalTurnsOption = CliOption('max-goal-turns',
    description: 'Bound goal turns (requires --goal; otherwise unlimited).',
    valueName: 'N',
    validate: _validateTurns);

void _validateGoal(String text) {
  if (text.trim().isEmpty || text.trim().length > goalMaxTextLength) {
    throw FormatException('--goal must be 1–$goalMaxTextLength characters');
  }
}

void _validateTurns(String text) {
  final turns = int.tryParse(text);
  if (turns == null || turns < 1) {
    throw const FormatException('--max-goal-turns requires a positive integer');
  }
}

final goalsCli = PluginCli(
  options: const [goalOption, maxGoalTurnsOption],
  validate: (args) {
    if (args.contains(maxGoalTurnsOption) && !args.contains(goalOption)) {
      throw const FormatException('--max-goal-turns requires --goal');
    }
  },
  sessionCommand: (args) {
    var text = args[goalOption];
    if (text == null) return null;
    final readsStdin = text == '-';
    final maxTurns = args[maxGoalTurnsOption];
    return CliSessionCommand(
      option: goalOption,
      readsStdin: readsStdin,
      prepare: (readStdin) async {
        if (readsStdin) text = await readStdin();
        _validateGoal(text!);
      },
      run: (plugin, context) async {
        var cancelled = false;
        final achieved = await (plugin as GoalsPlugin).runToGoal(
          text: text!,
          maxTurns: maxTurns == null ? null : int.parse(maxTurns),
          send: context.send,
          onTurn: (outcome) {
            final reply = context.lastReply();
            if (reply != null && reply.isNotEmpty) context.writeLine(reply);
            if (outcome.stopReason != StopReason.complete) {
              cancelled = outcome.stopReason == StopReason.cancelled;
              context.writeError(outcome.detail);
            }
          },
        );
        if (!achieved && !cancelled) {
          context.writeError(
              'tina: goal was not achieved or completion could not be verified');
        }
        return achieved
            ? 0
            : cancelled
                ? 130
                : 1;
      },
    );
  },
);
