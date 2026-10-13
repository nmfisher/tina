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

/// CLI input preparation for a registered session operation. No live plugin or
/// execution callback crosses into the CLI; any controller can invoke the same
/// operation through its session connection.
final class CliSessionCommand {
  const CliSessionCommand({
    required this.option,
    required this.operation,
    required this.prepare,
    this.readsStdin = false,
  });
  final CliOption option;
  final bool readsStdin;
  final String operation;

  /// Runs before session construction. Throws FormatException for bad input.
  final Future<Map<String, Object?>> Function(
      Future<String> Function() readStdin) prepare;
}
