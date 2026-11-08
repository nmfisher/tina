/// The no-`dart:io` stdout: a wasm composition root must inject a sink.
void nativeAppStdoutWriteln(String line) {
  throw UnsupportedError('no stdout on this platform: inject a sink');
}
