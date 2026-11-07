import 'dart:io' as io;

/// The native stdout sink.
void nativeAppStdoutWriteln(String line) {
  io.stdout.writeln(line);
}
