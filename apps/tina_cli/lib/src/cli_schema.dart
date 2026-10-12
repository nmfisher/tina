import 'package:tina_host/tina_host.dart';

/// One source for argument parsing, help and shell completion. Catalog collisions
/// are rejected even for disabled plugins, before any resources are constructed.
final class CliSchema {
  CliSchema({
    required List<CliOption> bootstrap,
    Map<String, PluginCli> plugins = const {},
  }) : plugins = Map.unmodifiable(plugins) {
    for (final option in bootstrap) {
      _add(option, null);
    }
    for (final entry in plugins.entries) {
      for (final option in entry.value.options) {
        _add(option, entry.key);
      }
    }
  }

  final Map<String, PluginCli> plugins;
  final _flags = <String, CliOption>{};
  final _owners = <CliOption, String?>{};
  Iterable<CliOption> get options => _owners.keys;

  void _add(CliOption option, String? owner) {
    if (!RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$').hasMatch(option.name) ||
        (option.abbreviation != null &&
            !RegExp(r'^[a-zA-Z]$').hasMatch(option.abbreviation!)) ||
        option.description.trim().isEmpty) {
      throw ArgumentError('Invalid CLI declaration: ${option.name}');
    }
    for (final flag in option.spellings) {
      if (_flags.containsKey(flag)) {
        throw ArgumentError(
          'Duplicate CLI flag $flag: '
          '${_owners[_flags[flag]] ?? "application"} and ${owner ?? "application"}',
        );
      }
      _flags[flag] = option;
    }
    _owners[option] = owner;
  }

  CliArguments parse(List<String> args) {
    final values = <CliOption, String?>{};
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      final equals = arg.startsWith('--') ? arg.indexOf('=') : -1;
      final flag = equals < 0 ? arg : arg.substring(0, equals);
      final option = _flags[flag];
      if (option == null) throw FormatException('unknown argument: $flag');
      String? value = equals < 0 ? null : arg.substring(equals + 1);
      if (option.value == CliValue.none) {
        if (value != null) throw FormatException('$flag does not take a value');
      } else {
        if (value == null &&
            i + 1 < args.length &&
            (args[i + 1] == '-' || !args[i + 1].startsWith('-'))) {
          value = args[++i];
        }
        if (value == null && option.value == CliValue.required) {
          throw FormatException(
            'incomplete argument: $flag requires ${option.valueName}',
          );
        }
        if (value != null) {
          if (option.choices.isNotEmpty && !option.choices.contains(value)) {
            throw FormatException('$flag must be ${option.choices.join(", ")}');
          }
          option.validate?.call(value);
        }
      }
      values[option] = value;
    }
    return CliArguments(values);
  }

  void validate(CliArguments args) {
    for (final contribution in plugins.values) {
      contribution.validate?.call(args);
    }
  }

  ({String owner, CliSessionCommand command})? sessionCommand(
    CliArguments args,
  ) {
    ({String owner, CliSessionCommand command})? selected;
    for (final entry in plugins.entries) {
      final command = entry.value.sessionCommand?.call(args);
      if (command == null) continue;
      if (_owners[command.option] != entry.key ||
          !args.contains(command.option)) {
        throw StateError(
          '${entry.key} selected a command without its own flag',
        );
      }
      if (selected != null) {
        throw FormatException(
          '${selected.command.option.flag} and '
          '${command.option.flag} are mutually exclusive',
        );
      }
      selected = (owner: entry.key, command: command);
    }
    return selected;
  }

  String get help {
    final result = StringBuffer(
      'usage: tina [options]\n\n'
      'Starts the terminal app. /help lists loaded session commands.\n'
      'Headless approval requests are denied; permission modes are never escalated.\n',
    );
    String? previousOwner;
    var first = true;
    for (final option in options) {
      final owner = _owners[option];
      if (first || owner != previousOwner) {
        result.writeln('\n${owner ?? "Application"}:');
        first = false;
        previousOwner = owner;
      }
      final suffix = switch (option.value) {
        CliValue.none => '',
        CliValue.required => ' ${option.valueName}',
        CliValue.optional => ' [${option.valueName}]',
      };
      result.writeln(
        '  ${option.spellings.join(", ")}$suffix\n'
        '      ${option.description}',
      );
      if (option.choices.isNotEmpty) {
        result.writeln('      Choices: ${option.choices.join(", ")}.');
      }
    }
    return result.toString();
  }
}
