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

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:tina_llm/tina_llm.dart';
import 'package:tina_core/tina_core.dart';
import 'package:wasm_components/wasm_components.dart' as cm;

import 'package:tina/src/app_io.dart';
import 'package:tina/src/assembly.dart';
import 'package:tina/src/persistence_seam.dart';
import 'package:tina/src/pipes.dart';
import 'package:tina/src/tools_factory.dart';
import 'package:tina_settings/tina_settings.dart';

import 'package:tina_persistence/session_store_api.dart';
import 'package:tina_wasm/src/components/tina_probe_engine_probe.dart' as root;
import 'package:tina_wasm/src/components/wasi_cli.dart' as wasi_cli;
import 'package:tina_wasm/src/components/wasmdart_tests.dart' as tests;
import 'package:tina_wasm/src/engine_registry.dart';
import 'package:tina_wasm/src/preloaded_app_io.dart';
import 'package:tina_wasm/src/portable_tools_plugin.dart';
import 'package:tina_wasm/src/plugin_admin.dart';
import 'package:tina_wasm/src/remote_prompt_plugin.dart';
import 'package:tina_wasm/src/wasm_prompt_bridge.dart';
import 'package:tina_wasm/src/wasm_persistence_plugin.dart';
import 'package:tina_wasm/src/wasi_session_store.dart';
import 'package:tina_wasm/src/wasi_tool_file_system.dart';
import 'package:tina_wasm/src/wasm_environment_port.dart';
import 'package:tina_wasm/src/wasm_file_system_port.dart';
import 'package:tina_wasm/src/wasm_http_endpoint.dart';

/// The ordered stdout queue (see [_TestedModule._emit]).
Future<void> _stdoutQueue = Future.value();

void main(List<String> arguments) {
  root.engineProbeComponent((imports) {
    return (
      unnamedExport27: _TestedModule(imports),
      unnamedExport16: const _Run(),
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
    try {
      await _boot();
    } catch (error, stack) {
      _emit('BOOT-ERROR: $error');
      for (final line in '$stack'.split('\n').take(12)) {
        _emit('BOOT-AT: $line');
      }
    }
  }

  Future<void> _boot() async {
    final environment = _environment();

    // 1. Preload the config tree and the workspace's `.tina` from the
    //    preopens: everything the synchronous assembly boot reads.
    final preopens = WasmPreopens(_imports.filesystemPreopens.getDirectories());
    final appIo = await PreloadedAppIo.load(
      preopens,
      _imports.filesystemTypes,
      roots: const ['config', '.tina'],
      environment: environment,
      home: 'config',
    );
    injectedAppIo = appIo;

    // 2. The portable tools plugin over the WASI filesystem, with the
    //    asking boundary: preopen attribution answers containment, the
    //    config preopen and the workspace `.tina` are protected, and the
    //    mode comes from the host (yolo unless TINA_ENGINE_YOLO=0).
    injectedToolsPluginFactory = (wiring) => PortableToolsPlugin(
      fileSystem: WasiToolFileSystem(preopens, _imports.filesystemTypes),
      workspaceRoot: wiring.workspaceRoot,
      mode: wiring.mode,
      protectedPaths: wiring.protectedPaths,
      isWithinWorkspace: (path) => preopens.guestRootOf(path) == '.',
    );

    // 3. The provider over `tina:http`, credentials from the host-set
    //    environment, never from the module.
    final http = _imports.httpClient;
    final envPort = WasmEnvironmentPort(_imports.cliEnvironment);
    LlmProvider provider(String model) {
      final base =
          environment['TINA_LLM_ENDPOINT'] ?? 'https://api.z.ai/api/anthropic';
      return AnthropicProvider(
        model: model,
        endpoint: WasmHttpEndpoint(endpoint: base, client: http),
        environment: envPort,
      );
    }

    // 4. The assembly: same code path as `tina --pipes`, with the wasm
    // registry, the preloaded backend, and the pipes protocol. Yolo is
    // the host's call (TINA_ENGINE_YOLO=0 boots in ask mode so approval
    // asks reach the client); persistence is too (TINA_ENGINE_STORE +
    // a config enabling tina/persistence; TINA_ENGINE_RESUME seeds a
    // stored session). No credentials either way.
    final backend = PreloadedSettingsBackend(
      appIo,
      globalPath: 'config/config',
      workspacePath: '.tina/config',
    );

    // The persistence store, when the host asks for one: load the JSONL
    // file from the preopens before the synchronous boot, and wire the
    // seam so the assembly's open/resume calls reach it instead of the
    // platform default (none under wasm).
    final storeSpec = environment['TINA_ENGINE_STORE'];
    final resumeId = environment['TINA_ENGINE_RESUME'];
    // The extension is opt-in and its artifact is selected by the host.
    // The guest receives no path or authority beyond this registered adapter.
    final includeRemotePromptPlugin =
        environment['TINA_WASM_PLUGIN_ID'] == RemotePromptPlugin.pluginId;
    WasiSessionStore? store;
    if (storeSpec != null) {
      store = await WasiSessionStore.open(
        storeSpec,
        preopens,
        _imports.filesystemTypes,
      );
    }
    WasmPersistencePlugin? persistencePlugin;
    if (store != null) {
      injectedPersistenceWiring = PersistenceWiring(
        openStore: (_) => store!,
        restoreSessionSettings: (settings, opened, sessionId) =>
            restoreSessionSettingsFromLog(
              settings as ScopedSettings,
              (opened as WasiSessionStore).readEntries(sessionId),
            ),
        storedSessionModel: (opened, sessionId) => (opened as WasiSessionStore)
            .list()
            .firstWhere(
              (row) => row.id == sessionId,
              orElse: () => throw SessionStoreException(
                'no session $sessionId in ${opened.file}',
              ),
            )
            .model,
      );
    }

    final assembly = SessionAssembly.start(
      providerFactory: provider,
      options: AssemblyOptions(
        configPath: 'config/config',
        workingDirectory: '.',
        storePath: storeSpec,
        sessionId: resumeId,
        yolo: environment['TINA_ENGINE_YOLO'] != '0',
        interactive: false,
        osSandbox: false,
        approvalChannel: 'tina/approvals-stream',
        registry: wasmEngineRegistry(
          persistenceStore: store,
          onPersistence: (plugin) => persistencePlugin = plugin,
          includeRemotePromptPlugin: includeRemotePromptPlugin,
          remotePromptHost: WasmPromptPluginHostBridge(
            _imports.pluginHostSession,
          ),
        ),
        settingsBackend: backend,
        plugins: [
          // The portable baseline; persistence joins only when the
          // composition root loaded a store for it (the baseline is
          // validated against the registry, so it cannot name what the
          // registry does not carry).
          'tina/system-instruction',
          'tina/providers',
          'tina/mode',
          'tina/tools',
          'tina/approvals-stream',
          'tina/session-controls',
          if (store != null) 'tina/persistence',
          if (includeRemotePromptPlugin) ...[
            RemotePromptPlugin.pluginId,
            WasmPluginAdminPlugin.pluginId,
          ],
        ],
      ),
    );
    try {
      // 5. The session: wasi stdin in, wasi stdout out, until shutdown.
      await runSessionPipes(assembly, input: _stdin(), emit: _emit);
      // The ordered stdout queue must drain before the export returns:
      // component streams created after the task's return are never
      // driven by the host's event loop.
      await _stdoutQueue;
    } finally {
      await assembly.shutdown();
      // The session store's writes are buffered memory until this flush:
      // the component's export has not returned yet, so the host's event
      // loop still drives the WASI streams.
      await persistencePlugin?.flush();
      injectedPersistenceWiring = null;
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
    // One line, one stream write, chained in order: concurrent streams
    // have no guaranteed write order, and the pipes protocol's events
    // must not interleave. UTF-8, never code units — a protocol line can
    // carry non-ASCII (an approval reason's em-dash) and codeUnits would
    // emit garbage bytes the client's decoder rejects.
    _stdoutQueue = _stdoutQueue.then(
      (_) => _imports.cliStdout.writeViaStream(
        data: Stream.value(Uint8List.fromList(utf8.encode('$line\n'))),
      ),
    );
  }
}
