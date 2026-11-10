/// `dart:io` variant of the platform seam: exactly the reads the ANSI path
/// made before the seam existed.
library;

import 'dart:io' as io;

/// The value of [name] in the process environment, or null.
String? platformEnv(String name) => io.Platform.environment[name];

/// Whether [name] appears in the process environment.
bool platformEnvHas(String name) => io.Platform.environment.containsKey(name);

/// Whether stdout accepts ANSI escape sequences.
bool platformStdoutSupportsAnsi() {
  try {
    return io.stdout.supportsAnsiEscapes;
  } catch (_) {
    return false;
  }
}

/// Append [contents] to the file at [path] (created if missing),
/// flushed synchronously so a debug log survives a kill — the stronger of
/// the two flush modes the pre-seam call sites used.
void platformAppendFile(String path, String contents) {
  io.File(path).writeAsStringSync(
    contents,
    mode: io.FileMode.append,
    flush: true,
  );
}
