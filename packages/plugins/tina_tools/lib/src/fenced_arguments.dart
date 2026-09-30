/// Builds arguments for a dedicated tool whose program supports an option
/// separator. Tool-owned options precede `--`; positional data follows it.
/// Generic ExecTool does not use this builder: it preserves the caller's argv.
/// Only use this for programs and command positions that support `--`.
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
