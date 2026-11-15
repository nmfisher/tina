/// The wasm probe: the shared [runProbe] body wired to the wasm port
/// implementations, exported through the case runner's tested-module
/// protocol so it runs under the Rust host (`pkg/test_runner`).
library;

import 'package:tina_wasm/src/components/tina_probe_engine_probe.dart' as root;
import 'package:tina_wasm/src/components/wasi_cli.dart' as wasi_cli;
import 'package:tina_wasm/src/components/wasmdart_tests.dart' as tests;
import 'package:tina_wasm/src/probe_body.dart';
import 'package:tina_wasm/src/wasm_environment_port.dart';
import 'package:tina_wasm/src/wasm_file_system_port.dart';
import 'package:tina_wasm/src/wasm_http_endpoint.dart';
import 'package:tina_core/tina_core.dart';
import 'package:wasm_components/wasm_components.dart' as cm;

void main(List<String> arguments) {
  root.engineProbeComponent((imports) {
    return (
      unnamedExport29: _TestedModule(imports),
      // The stage-3 probe does not use `tina:process`; the world grew the
      // import in stage 4, so the record supplies it unopened.
      unnamedExport18: const _Run(),
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
    final preopens = WasmPreopens(_imports.filesystemPreopens.getDirectories());
    await runProbe(
      files: WasmFileSystemPort(preopens, _imports.filesystemTypes),
      endpoint: (base) =>
          WasmHttpEndpoint(endpoint: base, client: _imports.httpClient),
      environment: WasmEnvironmentPort(_imports.cliEnvironment),
      clock: const SystemClock(),
      random: SystemRandom(),
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
