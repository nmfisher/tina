/// The wasm engine: tina's real headless session assembly (the same
/// `SessionAssembly` + `runSessionPipes` the native `tina --pipes`
/// runs), composed over the wasm ports — HTTP over `tina:http`, files
/// over WASI preopens, tools over the portable seam, config from the
/// preopened config tree — and driven through the case runner's
/// tested-module protocol.
///
/// Serving: `invoke-test(0)` preloads the config snapshot, boots the
/// assembly, and runs the pipes session over WASI stdin/stdout until
/// `shutdown` or EOF. The host's event loop drives the multi-step
/// session; the external pipes client is the same one that drives the
/// native engine.
library;

import 'dart:typed_data';

import 'package:tina_llm/tina_llm.dart';
import 'package:tina_core/tina_core.dart';
import 'package:wasm_components/wasm_components.dart' as cm;

import 'package:tina/src/app_io.dart';
import 'package:tina/src/app_stdout.dart';
import 'package:tina/src/assembly.dart';
import 'package:tina/src/pipes.dart';
import 'package:tina/src/tools_factory.dart';
import 'package:tina_settings/tina_settings.dart';

import 'package:tina_wasm/src/components/tina_probe_engine_probe.dart' as root;
import 'package:tina_wasm/src/components/wasi_cli.dart' as wasi_cli;
import 'package:tina_wasm/src/components/wasi_filesystem.dart' as fs;
import 'package:tina_wasm/src/components/wasmdart_tests.dart' as tests;
import 'package:tina_wasm/src/engine_registry.dart';
import 'package:tina_wasm/src/preloaded_app_io.dart';
import 'package:tina_wasm/src/portable_tools_plugin.dart';
import 'package:tina_wasm/src/wasi_tool_file_system.dart';
import 'package:tina_wasm/src/wasm_environment_port.dart';
import 'package:tina_wasm/src/wasm_file_system_port.dart';
import 'package:tina_wasm/src/wasm_http_endpoint.dart';

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
    final environment = _environment();

    // 1. Preload the config tree and the workspace's `.tina` from the
    //    preopens: everything the synchronous assembly boot reads.
    final preopens =
        WasmPreopens(_imports.filesystemPreopens.getDirectories());
    final appIo = await PreloadedAppIo.load(
      preopens,
      _imports.filesystemTypes,
      roots: const ['config', '.tina'],
      environment: environment,
      home: 'config',
    );
    injectedAppIo = appIo;

    // 2. The portable tools plugin over the WASI filesystem.
    injectedToolsPluginFactory = (wiring) => PortableToolsPlugin(
          fileSystem: WasiToolFileSystem(
            preopens,
            _imports.filesystemTypes,
          ),
          workspaceRoot: wiring.workspaceRoot,
          mode: wiring.mode,
        );

    // 3. The provider over `tina:http`, credentials from the host-set
    //    environment, never from the module.
    final http = _imports.httpClient;
    final envPort = WasmEnvironmentPort(_imports.cliEnvironment);
    LlmProvider provider(String model) {
      final base = environment['TINA_LLM_ENDPOINT'] ??
          'https://api.z.ai/api/anthropic';
      return AnthropicProvider(
        model: model,
        endpoint: WasmHttpEndpoint(endpoint: base, client: http),
        environment: envPort,
      );
    }

    // 4. The assembly: same code path as `tina --pipes`, with the wasm
    //    registry, the preloaded backend, and the pipes protocol.
    final backend = PreloadedSettingsBackend(
      appIo,
      globalPath: 'config/config',
      workspacePath: '.tina/config',
    );
    final assembly = SessionAssembly.start(
      providerFactory: provider,
      options: AssemblyOptions(
        configPath: 'config/config',
        workingDirectory: '.',
        yolo: true,
        interactive: false,
        osSandbox: false,
        approvalChannel: 'tina/approvals-stream',
        registry: wasmEngineRegistry(),
        settingsBackend: backend,
        plugins: const [
          'tina/system-instruction',
          'tina/providers',
          'tina/mode',
          'tina/tools',
          'tina/approvals-stream',
          'tina/session-controls',
        ],
      ),
    );
    try {
      // 5. The session: wasi stdin in, wasi stdout out, until shutdown.
      await runSessionPipes(
        assembly,
        input: _stdin(),
        emit: _emit,
      );
    } finally {
      await assembly.shutdown();
    }
  }

  Map<String, String> _environment() => {
        for (final (name, value) in _imports.cliEnvironment.getEnvironment())
          name: value,
      };

  Stream<Uint8List>? _stdin() {
    final (stream, _) = _imports.cliStdin.readViaStream();
    return stream;
  }

  void _emit(String line) {
    // One line, one stream write: the host's stdout tracking sees each.
    _imports.cliStdout.writeViaStream(
      data: Stream.value(Uint8List.fromList('$line\n'.codeUnits)),
    );
  }
}
