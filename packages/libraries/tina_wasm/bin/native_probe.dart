/// The native probe: the shared [runProbe] body wired to the native
/// `tina_io` ports, run on the VM. Its recorded lines must be identical
/// to the wasm probe's under the Rust runner - that equality is the
/// stage-3 exit test.
library;

import 'dart:convert';
import 'dart:io' as io;

import 'package:tina_core/tina_core.dart';
import 'package:tina_io/tina_io.dart';
import 'package:tina_wasm/src/probe_body.dart';

void main(List<String> arguments) async {
  final recorder = _PrintRecorder();
  await runProbe(
    files: const IoFileSystemPort(),
    endpoint: (base) => IoHttpEndpoint(endpoint: base),
    environment: const IoEnvironmentPort(),
    clock: const SystemClock(),
    random: SystemRandom(),
    recorder: recorder,
  );
  // Match the runner's trailing flush discipline: native exits when the
  // main future completes and pending prints have landed.
  await io.stdout.flush();
}

/// Prints the same JSON lines `run_native` prints for case bodies.
final class _PrintRecorder implements ProbeRecorder {
  @override
  void string(String value) => _line('string', value);

  @override
  void integer(int value) => _line('int', value);

  @override
  void boolean(bool value) => _line('bool', value);

  void _line(String type, Object value) {
    print(json.encode({'type': type, 'value': value}));
  }
}
