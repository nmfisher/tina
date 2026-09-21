/// Builds a process argument list in which model-supplied values are
/// unambiguously data.
///
/// A program cannot tell a value from an option: both are just strings in
/// `argv`. That is the whole of the `grep` bug — a pattern of
/// `--pre=<cmd>` was handed to ripgrep as a bare token and read as a flag
/// that runs a command — and no amount of care at the call site fixes the
/// class, because the next tool author has to remember too.
///
/// So argv for a spawning tool is assembled through this type instead. Options
/// go in the option region; every model-derived value goes after the `--`
/// fence, where the program is required to treat it as a positional. A value
/// therefore *cannot* be emitted in the option region — [build] is the only
/// way out, and it is what puts the fence in.
///
/// ```dart
/// final args = FencedArguments()
///   ..flag('--no-heading')
///   ..option('--glob', glob)   // one token: `--glob=<value>`
///   ..value(pattern)           // model data, fenced
///   ..value(path);
/// processRunner.start('rg', args.build());
/// ```
///
/// A tool whose capability is `SpawnScope.fixed` is expected to use this, and
/// the argv sweep drives every such tool with hostile input to prove it did.
class FencedArguments {
  final List<String> _options = <String>[];
  final List<String> _values = <String>[];

  /// A flag with no value.
  void flag(String name) => _options.add(name);

  /// A flag and its value as ONE token (`--glob=<value>`), so a value that
  /// begins with a dash cannot be read as a second option. Use this rather
  /// than emitting the flag and its value as separate tokens.
  void option(String name, String value) => _options.add('$name=$value');

  /// A positional value — the model's data. Emitted after the fence.
  void value(String value) => _values.add(value);

  /// The argv to hand the process.
  ///
  /// The fence is emitted only when there is something to fence, so a tool
  /// with no model input pays nothing for the discipline.
  List<String> build() =>
      <String>[..._options, if (_values.isNotEmpty) '--', ..._values];
}
