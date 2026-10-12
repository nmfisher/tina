import 'package:tina_engine_2/tina_engine_2.dart';

enum CliValue { none, required, optional }

enum CliCompletion { none, file, directory }

/// Startup metadata available before a plugin or session exists. The application
/// owns parsing and process I/O; the agent loop does not know about CLI flags.
final class CliOption {
  const CliOption(
    this.name, {
    required this.description,
    this.abbreviation,
    this.value = CliValue.required,
    this.valueName = 'VALUE',
    this.choices = const [],
    this.completion = CliCompletion.none,
    this.validate,
  });
  final String name;
  final String description;
  final String? abbreviation;
  final CliValue value;
  final String valueName;
  final List<String> choices;
  final CliCompletion completion;
  final void Function(String)? validate;
  String get flag => '--$name';
  List<String> get spellings =>
      [flag, if (abbreviation != null) '-$abbreviation'];
}

/// Declaration objects are keys, so consumers do not repeat flag names.
final class CliArguments {
  CliArguments(Map<CliOption, String?> values)
      : _values = Map.unmodifiable(values);
  final Map<CliOption, String?> _values;
  bool contains(CliOption option) => _values.containsKey(option);
  String? operator [](CliOption option) => _values[option];
}

final class PluginCli {
  const PluginCli({required this.options, this.validate, this.sessionCommand});
  final List<CliOption> options;
  final void Function(CliArguments)? validate;

  /// Selects a command without constructing plugins or performing I/O.
  final CliSessionCommand? Function(CliArguments)? sessionCommand;
}

/// A plugin-owned headless entry point. The application handles signals and
/// shutdown, and resolves the owning plugin by its registered ID.
final class CliSessionCommand {
  const CliSessionCommand({
    required this.option,
    required this.run,
    this.readsStdin = false,
    this.prepare,
  });
  final CliOption option;
  final bool readsStdin;

  /// Runs before session construction. Throws FormatException for bad input.
  final Future<void> Function(Future<String> Function() readStdin)? prepare;
  final Future<int> Function(AgentPlugin plugin, CliSessionContext context) run;
}

/// Plugins receive session operations and output sinks, never process streams
/// or signal handlers.
final class CliSessionContext {
  const CliSessionContext({
    required this.send,
    required this.lastReply,
    required this.writeLine,
    required this.writeError,
  });
  final Future<Outcome> Function(String) send;
  final String? Function() lastReply;
  final void Function(String) writeLine;
  final void Function(String) writeError;
}
