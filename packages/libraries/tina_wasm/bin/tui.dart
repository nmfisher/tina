/// The wasm TUI guest (Option 2 production): tina's real session assembly
/// (the same `SessionAssembly` the pipes engine and native `tina` boot)
/// with the REAL front end — `runTui`/`runApp`, the `AnsiBackend`, the
/// `LineEditor`, the status strip — compiled into one component and driven
/// over WASI stdio, the host's tty authority and the crash channel.
///
/// Serving: the `run` export preloads the config snapshot, boots the
/// assembly exactly like `bin/engine.dart`, wraps it in the in-process
/// `TuiSession`, and runs the native TUI loop until quit. The body runs
/// inside a zone guard (spike finding 4): an uncaught Dart exception calls
/// `tina:term/crash.fail` with the message — the host surfaces
/// `guest crashed: <message>` and restores the terminal — and then invokes
/// the WASI `exit` import so the host's `run` call can never park.
///
/// Build: `TINA_WASM_ABI=lib/src/components/tina_probe_tui_app.json \
///   dart run wasm_tools compile bin/tui.dart` (the link hook follows the
/// env var; the engine build keeps its default).
library;

import 'dart:async';

import 'package:tina_llm/tina_llm.dart';
import 'package:tina_core/tina_core.dart';
import 'package:wasm_components/wasm_components.dart' as cm;

import 'package:tina/src/app_io.dart';
import 'package:tina/src/assembly.dart';
import 'package:tina/src/persistence_seam.dart';
import 'package:tina/src/tools_factory.dart';
import 'package:tina/src/tui_session.dart' show TuiSession, TuiSessionHandle;
import 'package:tina_settings/tina_settings.dart';

import 'package:tina_persistence/session_store_api.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/backend/ansi_input_backend.dart';
import 'package:tina_tui/tina_tui.dart' show runApp;

import 'package:tina_wasm/src/components/tina_probe_tui_app.dart' as root;
import 'package:tina_wasm/src/components/wasi_cli.dart' as wasi_cli;
import 'package:tina_wasm/src/engine_registry.dart';
import 'package:tina_wasm/src/preloaded_app_io.dart';
import 'package:tina_wasm/src/portable_tools_plugin.dart';
import 'package:tina_wasm/src/plugin_admin.dart';
import 'package:tina_wasm/src/remote_prompt_plugin.dart';
import 'package:tina_wasm/src/wasi_stdio.dart';
import 'package:tina_wasm/src/wasm_prompt_bridge.dart';
import 'package:tina_wasm/src/wasm_persistence_plugin.dart';
import 'package:tina_wasm/src/wasi_session_store.dart';
import 'package:tina_wasm/src/wasi_tool_file_system.dart';
import 'package:tina_wasm/src/wasm_environment_port.dart';
import 'package:tina_wasm/src/wasm_file_system_port.dart';
import 'package:tina_wasm/src/wasm_http_endpoint.dart';

/// The guest's imports + stdio, captured once `main` wires the component;
/// the zone guard and the run loop both need them.
root.TuiAppImports? _imports;
WasiStdio? _stdio;

/// The host-reported crash channel + loud death. Called only from the
/// zone guard: `fail` first (the host records the message and stops
/// waiting), then the WASI `exit` import — the structural backstop that
/// ends the instance so the host's `run` call resolves with an error and
/// the terminal is restored. Never park.
void _crash(Object error) {
  final imports = _imports;
  final summary = '$error';
  try {
    imports?.termCrash.fail(
      message: summary.length > 2000 ? summary.substring(0, 2000) : summary,
    );
  } catch (_) {
    // The host import refusing is not survivable either way; fall through
    // to the exit below so the host still sees the failure.
  }
  try {
    imports?.cliExit.exit(status: const cm.ErrorResult(null));
  } catch (_) {}
  // If the exit import somehow returned, die loudly anyway.
  throw StateError('guest crashed and the exit backstop did not end the '
      'instance: $summary');
}

void main(List<String> arguments) {
  runZonedGuarded(() {
    root.tuiAppComponent((imports) {
      _imports = imports;
      _stdio = WasiStdio(imports);
      return _TuiRun();
    });
  }, (error, stack) {
    _crash(error);
  });
}

final class _TuiRun implements wasi_cli.Run {
  const _TuiRun();

  @override
  Future<cm.Result<void, void>> run() async {
    try {
      await _boot();
      await _stdio?.drain();
      return const cm.OkResult(null);
    } catch (error) {
      await _stdio?.drain();
      _crash(error);
      return const cm.ErrorResult(null); // unreachable; satisfies the type
    }
  }

  Future<void> _boot() async {
    final imports = _imports!;
    final stdio = _stdio!;
    final environment = _environment(imports);

    // 1-4: identical to the pipes engine's boot (bin/engine.dart): the
    // preopened config snapshot, the portable tools plugin, the tina:http
    // provider, the assembly — `interactive: true`, because a human is on
    // the other end of this component.
    final preopens = WasmPreopens(imports.filesystemPreopens.getDirectories());
    final appIo = await PreloadedAppIo.load(
      preopens,
      imports.filesystemTypes,
      roots: const ['config', '.tina'],
      environment: environment,
      home: 'config',
    );
    injectedAppIo = appIo;

    injectedToolsPluginFactory = (wiring) => PortableToolsPlugin(
      fileSystem: WasiToolFileSystem(preopens, imports.filesystemTypes),
      workspaceRoot: wiring.workspaceRoot,
      mode: wiring.mode,
      protectedPaths: wiring.protectedPaths,
      isWithinWorkspace: (path) => preopens.guestRootOf(path) == '.',
    );

    final http = imports.httpClient;
    final envPort = WasmEnvironmentPort(imports.cliEnvironment);
    LlmProvider provider(String model) {
      final base =
          environment['TINA_LLM_ENDPOINT'] ?? 'https://api.z.ai/api/anthropic';
      return AnthropicProvider(
        model: model,
        endpoint: WasmHttpEndpoint(endpoint: base, client: http),
        environment: envPort,
      );
    }

    final backend = PreloadedSettingsBackend(
      appIo,
      globalPath: 'config/config',
      workspacePath: '.tina/config',
    );

    final storeSpec = environment['TINA_ENGINE_STORE'];
    final resumeId = environment['TINA_ENGINE_RESUME'];
    final includeRemotePromptPlugin =
        environment['TINA_WASM_PLUGIN_ID'] == RemotePromptPlugin.pluginId;
    WasiSessionStore? store;
    if (storeSpec != null) {
      store = await WasiSessionStore.open(
        storeSpec,
        preopens,
        imports.filesystemTypes,
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
        interactive: true,
        osSandbox: false,
        approvalChannel: 'tina/approvals-stream',
        registry: wasmEngineRegistry(
          persistenceStore: store,
          onPersistence: (plugin) => persistencePlugin = plugin,
          includeRemotePromptPlugin: includeRemotePromptPlugin,
          remotePromptHost: WasmPromptPluginHostBridge(
            imports.pluginHostSession,
          ),
        ),
        settingsBackend: backend,
        // The host owns the capability document on wasm (it ingests the
        // launcher's --capabilities file or derives discovery itself); the
        // guest compiles nothing - the compiler inputs read the process's
        // own files, which a component cannot.
        compileCapabilities: false,
        plugins: [
          'tina/system-instruction',
          'tina/providers',
          'tina/mode',
          'tina/tools',
          'tina/approvals-stream',
          'tina/session-controls',
          'tina/chat-tui',
          if (store != null) 'tina/persistence',
          if (includeRemotePromptPlugin) ...[
            RemotePromptPlugin.pluginId,
            WasmPluginAdminPlugin.pluginId,
          ],
        ],
      ),
    );

    try {
      // 5: the REAL front end over WASI stdio, exactly the surface the
      // native `tina` TUI drives — no spike-era bespoke painting. The
      // screen arrives pre-built (the composition root owns the WASI
      // Stdio), the editor rides the same bytes, and resize is the tty
      // poll (WASI has no guest-side signals; 250 ms as spike-proven).
      final (initialCols, initialRows) = imports.termTty.getSize();
      stdio.noteSize(initialCols, initialRows);

      final screen = Screen.withBackend(
        backend: createAnsiBackend(io: stdio, ansi: AnsiCapable.yes),
        io: stdio,
        layout: ScreenLayout.fromSize(initialCols, initialRows, split: false),
        ansi: AnsiCapable.yes,
        theme: const Theme.defaults(),
      );

      final session = TuiSession.wrap(assembly);
      await _runTui(
        session,
        screen: screen,
        editorFor: (s) => LineEditor(
          screen: s,
          input: AnsiInputBackend(io: stdio),
        ),
        resizes: _resizeStream(imports, stdio, initialCols, initialRows),
        environment: environment,
      );
      // Buffered store writes must flush while the host's event loop still
      // drives the WASI streams (the export has not returned yet).
      await persistencePlugin?.flush();
    } finally {
      await assembly.shutdown();
      injectedPersistenceWiring = null;
    }
  }

  /// The native `runTui` body (apps/tina_cli/lib/src/tui_app.dart), mirrored
  /// here instead of imported: that file's import set drags the native CLI
  /// plugin catalog (sqlite, dart:io plugin layers) into the wasm closure,
  /// while its body is exactly this wrapper over the wasm-clean `runApp`.
  /// Under wasm: no StartupTerminal (the host owns the terminal), backend
  /// fixed to ANSI, child sessions ride the same in-process session.
  Future<int> _runTui(
    TuiSessionHandle session, {
    required Screen screen,
    required LineEditor Function(Screen) editorFor,
    required Stream<ScreenLayout> resizes,
    required Map<String, String> environment,
  }) async {
    final owned = <ConsoleSessionView, TuiSessionHandle>{};
    Future<void>? shutdownResult;
    Future<void> shutdown() => shutdownResult ??= Future.wait(
      {session, ...owned.values}.map((owner) => owner.shutdown()),
    );
    try {
      final view = session.createView(showConfig: true);
      owned[view] = session;
      return await runApp(
        view,
        screen: screen,
        editorFor: editorFor,
        resizes: resizes,
        backend: 'ansi',
        environment: environment,
        workspace: session.createWorkspace(),
        createSession: (model) async {
          final child = session.spawn(model);
          try {
            final childView = child.createView();
            owned[childView] = child;
            return childView;
          } catch (_) {
            await child.shutdown();
            rethrow;
          }
        },
        onViewClosed: (view, pendingWork) async {
          final owner = owned[view];
          if (owner == null) return;
          if (identical(owner, session)) {
            owner.cancel();
            await pendingWork;
          } else {
            await Future.wait<void>([owner.shutdown(), pendingWork]);
          }
          owned.remove(view);
        },
        onExit: shutdown,
      );
    } finally {
      for (final view in owned.keys) {
        view.close();
      }
      await shutdown();
    }
  }

  /// The tty poll: `tina:term/tty.get-size` every 250 ms, a layout event on
  /// change (the spike-proven path; push-on-SIGWINCH is the follow-up).
  Stream<ScreenLayout> _resizeStream(
    root.TuiAppImports imports,
    WasiStdio stdio,
    int cols,
    int rows,
  ) {
    late StreamController<ScreenLayout> controller;
    Timer? timer;
    var lastCols = cols;
    var lastRows = rows;
    controller = StreamController<ScreenLayout>(
      onListen: () {
        timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
          final (c, r) = imports.termTty.getSize();
          if (c != lastCols || r != lastRows) {
            lastCols = c;
            lastRows = r;
            stdio.noteSize(c, r);
            controller.add(ScreenLayout.fromSize(c, r, split: false));
          }
        });
      },
      onCancel: () {
        timer?.cancel();
      },
    );
    return controller.stream;
  }

  Map<String, String> _environment(root.TuiAppImports imports) => {
    for (final (name, value) in imports.cliEnvironment.getEnvironment())
      name: value,
  };
}
