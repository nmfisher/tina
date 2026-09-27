/// The terminal seam — what a front end contributes to a session, and the
/// only way a plugin touches the user.
///
/// In production the front end builds a terminal that writes to stdout;
/// in tests a capturing terminal goes into the same slot. No plugin ever
/// sees `dart:io`'s stdout directly: **stdio lives at the edge only.**
library;

import 'dart:io';

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

/// The terminal over stdin/stdout. Production's terminal; tests
/// substitute a capturing one.
final class IoTerminal implements Terminal {
  const IoTerminal();

  @override
  void writeln([String? line]) {
    stdout.writeln(line ?? '');
  }

  @override
  Future<String> ask(String prompt) async {
    stdout.write(prompt);
    final line = stdin.readLineSync();
    return line?.trim() ?? '';
  }
}
