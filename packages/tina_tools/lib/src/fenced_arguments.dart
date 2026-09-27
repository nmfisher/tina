/// Builds a process argument list in which model-supplied values are
/// unambiguously data.
///
/// A program cannot tell a value from an option: both are just strings in
/// `argv`. That is the whole injection class — a model value like
/// `--pre=rm -rf /` handed over as a bare token is read by the program as a
/// flag that runs a command — and no amount of care at the call site fixes
/// the class, because the next tool author has to remember too.
///
/// So argv for [ExecTool] is assembled through this type instead. Options go
/// in the option region; every model-derived value goes after the `--`
/// fence, where POSIX argument parsing requires the program to treat it as
/// positional. A value therefore *cannot* be emitted in the option region:
/// [build] is the only way out, and it is what puts the fence in.
///
/// ```dart
/// final args = FencedArguments()
///   ..flag('--no-heading')
///   ..value(pattern)   // model data — lands after `--`, always
///   ..value(path);
/// final request = requestFor('rg', args);
/// ```
class FencedArguments {
  final List<String> _options = <String>[];
  final List<String> _values = <String>[];

  /// A flag with no value, emitted before the fence.
  void flag(String name) => _options.add(name);

  /// A flag and its value as ONE token (`--glob=<value>`), so a value that
  /// begins with a dash still cannot be read as a second option. Only for
  /// values the *tool itself* derives (defaults, resolved paths); model
  /// values belong behind the fence via [value].
  void option(String name, String value) => _options.add('$name=$value');

  /// A positional value — the model's data. Emitted after the fence,
  /// whatever it looks like.
  void value(String value) => _values.add(value);

  /// The argv to hand the process.
  ///
  /// The fence is emitted only when there is something to fence, so a call
  /// with no model input pays nothing for the discipline.
  List<String> build() =>
      <String>[..._options, if (_values.isNotEmpty) '--', ..._values];

  /// True when at least one model value is fenced. A test can assert on
  /// this, but the real assertion is on the argv [build] emits.
  bool get hasFence => _values.isNotEmpty;
}
