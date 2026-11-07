/// The wasm process probe: the shared [runProcessProbe] body wired to
/// the `tina:process` host import, exported through the case runner's
/// tested-module protocol so it runs under the Rust host
/// (`pkg/test_runner`).
library;

import 'package:wasm_components/wasm_components.dart' as cm;

import 'package:tina_wasm/src/components/tina_probe_engine_probe.dart' as root;
import 'package:tina_wasm/src/components/wasi_cli.dart' as wasi_cli;
import 'package:tina_wasm/src/components/wasmdart_tests.dart' as tests;
import 'package:tina_wasm/src/process_probe_body.dart';
import 'package:tina_wasm/src/probe_body.dart';
import 'package:tina_wasm/src/wasm_process_port.dart';

void main(List<String> arguments) {
  root.engineProbeComponent((imports) {
    return (
      unnamedExport26: _TestedModule(imports),
      unnamedExport15: const _Run(),
    );
  });
}

final class _Run implements wasi_cli.Run {
  const _Run();

  @override
  Future<cm.Result<void, void>> run() async => const cm.OkResult(null);
}

final class _TestedModule implements tests.TestedModule {
  final root.EngineProbeImports _imports;

  const _TestedModule(this._imports);

  @override
  int countTests() => 1;

  @override
  Future<void> invokeTest({required int number}) async {
    assert(number == 0);
    final recorder = _Collector(_imports.testsResultCollector);
    await runProcessProbe(
      processes: WasmProcessPort(
        process: _imports.processProcess,
        profile: processProbeProfile,
        approver: (request) => processProbeApprover(request, recorder),
      ),
      recorder: recorder,
    );
  }
}

/// Records through the result-collector import; the host prints one JSON
/// line per record, the same lines `run_native` prints natively.
final class _Collector implements ProbeRecorder {
  final tests.ResultCollector _sink;

  const _Collector(this._sink);

  @override
  void string(String value) => _sink.recordString(e: value);

  @override
  void integer(int value) => _sink.recordInt(e: value);

  @override
  void boolean(bool value) => _sink.recordBool(e: value);
}
