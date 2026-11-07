/// The native process probe: the shared [runProcessProbe] body wired to
/// the native `tina_io` port, run on the VM. Its recorded lines must be
/// identical to the wasm probe's under the Rust runner - that equality
/// is the stage-4 exit test: the same policy, evaluated engine-side
/// natively and host-side under wasm, behaves the same.
library;

import 'dart:convert';
import 'dart:io' as io;

import 'package:tina_io/tina_io.dart';
import 'package:tina_wasm/src/process_probe_body.dart';
import 'package:tina_wasm/src/probe_body.dart';

void main(List<String> arguments) async {
  final recorder = _PrintRecorder();
  // The same start/end markers the wasm run's host posts, so the two
  // outputs diff byte for byte.
  print(json.encode({'type': 'start', 'test': 0}));
  await runProcessProbe(
    processes: IoProcessPort(
      profile: processProbeProfile,
      approver: (request) => processProbeApprover(request, recorder),
    ),
    recorder: recorder,
  );
  print(json.encode({'type': 'end', 'test': 0}));
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
