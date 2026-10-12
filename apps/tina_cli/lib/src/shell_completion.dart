import 'package:tina_host/tina_host.dart';
import 'cli_options.dart';
import 'cli_schema.dart';

/// Offline scripts generated from the same declarations as parsing and help.
String shellCompletion(String shell, {CliSchema? schema}) {
  schema ??= applicationCliSchema();
  return switch (shell) {
    'bash' => _bash(schema),
    'zsh' => _zsh(schema),
    'fish' => _fish(schema),
    _ => throw const FormatException(
      'completion shell must be bash, zsh or fish',
    ),
  };
}

String _quote(String text) => "'${text.replaceAll("'", "'\\''")}'";

String _bash(CliSchema schema) {
  final out = StringBuffer(r'''_tina_complete() {
  local cur="${COMP_WORDS[COMP_CWORD]}" prev="${COMP_WORDS[COMP_CWORD-1]}"
  COMPREPLY=()
  case "$prev" in
''');
  for (final option in schema.options.where((o) => o.value != CliValue.none)) {
    out.write('    ${option.spellings.join("|")}) ');
    if (option.value == CliValue.optional) {
      out.write(r'if [[ "$cur" != -* ]]; then ');
    }
    if (option.choices.isNotEmpty) {
      out.write(
        'COMPREPLY=( \$(compgen -W ${_quote(option.choices.map(_quote).join(" "))} -- "\$cur") ); ',
      );
    } else if (option.completion != CliCompletion.none) {
      final kind = option.completion == CliCompletion.directory ? '-d' : '-f';
      out.write(
        'while IFS= read -r item; do COMPREPLY+=("\$item"); done < <(compgen $kind -- "\$cur"); ',
      );
    }
    out.write('return;');
    out.writeln(option.value == CliValue.optional ? ' fi;;' : ';');
  }
  out.writeln('  esac');
  out.writeln(
    '  COMPREPLY=( \$(compgen -W ${_quote(schema.options.expand((o) => o.spellings).join(" "))} -- "\$cur") )',
  );
  out.write('}\ncomplete -F _tina_complete tina');
  return out.toString();
}

String _zshText(String text) =>
    text.replaceAllMapped(RegExp(r'[\\\[\]:]'), (match) => '\\${match[0]}');

String _zsh(CliSchema schema) {
  final specs = <String>[];
  for (final option in schema.options) {
    final argument = switch (option.value) {
      CliValue.none => '',
      CliValue.required => ':${_zshText(option.valueName)}:',
      CliValue.optional => '::${_zshText(option.valueName)}:',
    };
    final action = option.value == CliValue.none
        ? ''
        : option.choices.isNotEmpty
        ? '(${option.choices.map(_quote).join(" ")})'
        : switch (option.completion) {
            CliCompletion.file => '_files',
            CliCompletion.directory => '_files -/',
            CliCompletion.none => '',
          };
    for (final flag in option.spellings) {
      specs.add(
        _quote('$flag[${_zshText(option.description)}]$argument$action'),
      );
    }
  }
  return '#compdef tina\n_tina() {\n  _arguments ${specs.join(" \\\n    ")}\n}\ncompdef _tina tina';
}

String _fish(CliSchema schema) {
  final out = StringBuffer('complete -c tina -f\n');
  for (final option in schema.options) {
    out.write('complete -c tina -l ${option.name}');
    if (option.abbreviation != null) out.write(' -s ${option.abbreviation}');
    if (option.value == CliValue.required) out.write(' -r');
    if (option.completion == CliCompletion.file) out.write(' -F');
    if (option.completion == CliCompletion.directory) {
      out.write(" -a '(__fish_complete_directories)'");
    }
    if (option.choices.isNotEmpty)
      out.write(' -a ${_quote(option.choices.map(_quote).join(" "))}');
    out.writeln(' -d ${_quote(option.description)}');
  }
  return out.toString().trimRight();
}
