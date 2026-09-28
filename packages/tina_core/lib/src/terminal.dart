/// Everything the shell says, and everything a plugin may say, goes
/// through here.
abstract interface class Terminal {
  /// Write one line. A null line writes a blank line.
  void writeln([String? line]);

  /// Ask the user [prompt]; resolves with the entered line, trimmed —
  /// an empty answer is `''`, never null (the shell's read loop owns
  /// end-of-input; nothing here can signal it).
  Future<String> ask(String prompt);
}
