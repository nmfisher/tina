library;

import 'package:tina_core/tina_core.dart';
import 'package:tina_host/tina_host.dart';

/// What one entered line means. A pure value — no terminal, no I/O.
sealed class CommandDecision {
  const CommandDecision();
}

/// The line named a published command; [run] executes its handler with
/// the argument text (everything after the word, trimmed).
final class RunCommand extends CommandDecision {
  final Command command;
  final String argument;
  const RunCommand(this.command, this.argument);

  /// The handler runs; it reports through the [Terminal] it resolves.
  Future<void> run() async => await command.handler(argument);
}

/// The line was `/word` but no plugin published that word. Reported,
/// never swallowed — and never run as a turn.
final class UnknownCommand extends CommandDecision {
  final String name;
  const UnknownCommand(this.name);

  /// The same refusal the assembly's writer prints, through the TUI's
  /// terminal.
  void report(void Function(String line) writeln) =>
      writeln('unknown command: /$name');
}

/// An ordinary line: a turn's input, not a command. [text] is the
/// trimmed line; empty for an empty line (no turn).
final class PlainLine extends CommandDecision {
  final String text;
  const PlainLine(this.text);

  @override
  bool operator ==(Object other) => other is PlainLine && text == other.text;

  @override
  int get hashCode => text.hashCode;
}

/// The pure dispatch decision: which command does [line] mean, if any?
///
/// The rules are the assembly's, so a rendered run and a headless run
/// dispatch the same line the same way: trim; a leading `/` splits into
/// the first word (the command) and the rest (the argument, trimmed); a
/// published word runs, an unpublished one is unknown; anything else is
/// a plain line.
/// A registered prefix alias passes all text after its prefix as the argument.
CommandDecision dispatchLine(Commands commands, String line) {
  final trimmed = line.trim();
  final prefixed = commands.matchPrefix(trimmed);
  if (prefixed != null) {
    return RunCommand(prefixed.command, prefixed.argument);
  }
  if (!trimmed.startsWith('/')) {
    return PlainLine(trimmed);
  }
  final rest = trimmed.substring(1);
  final split = RegExp(r'\s').firstMatch(rest);
  final word = split == null ? rest : rest.substring(0, split.start);
  final argument = split == null ? '' : rest.substring(split.end).trim();
  final command = commands[word];
  if (command == null) {
    return UnknownCommand(word);
  }
  return RunCommand(command, argument);
}

/// The command list, one row per published command — names, descriptions
/// and hints read from the registry, sorted as [Commands.all] sorts
/// them. This is the whole presentation: nothing here (or anywhere in
/// tina_tui) names a command.
List<String> commandListRows(Commands commands) => [
      for (final c in commands.all) '/${c.name} — ${c.description}',
    ];
