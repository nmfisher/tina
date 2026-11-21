/// The admin plugin mounts on every wasm session (owner ruling,
/// v0.10.12): the registry carries tina/wasm-plugin-admin without the
/// remote-prompt opt-in, a plain-session plugin shows the lifecycle
/// tools and the prompt section, and the remote-prompt extension stays
/// exactly as gated as before — including that an idle admin lease book
/// never touches the host bridge.
@Tags(['wasm-runtime'])
library;

import 'package:tina_core/tina_core.dart' show Terminal;
import 'package:tina_engine_2/tina_engine_2.dart'
    show AgentLoop, Input, ScriptedProvider, scriptedReply;
import 'package:test/test.dart';
import 'package:tina_wasm/src/engine_registry.dart';
import 'package:tina_wasm/src/plugin_admin.dart';
import 'package:tina_wasm/src/plugin_manager.dart';
import 'package:tina_wasm/src/remote_prompt_plugin.dart';

final class _RecordingBridge implements PromptPluginHostBridge {
  final opened = <String>[];

  @override
  PromptBridgeResult<String> open() {
    final lease = 'lease-${opened.length + 1}';
    opened.add(lease);
    return PromptBridgeResult<String>.ok(lease);
  }

  @override
  Future<PromptBridgeResult<String>> onPrompt({
    required String lease,
    required String sessionId,
    required String model,
  }) async {
    return const PromptBridgeResult<String>.error(
      PromptBridgeFailure.denied,
    );
  }

  @override
  PromptBridgeResult<void> close({required String lease}) {
    return const PromptBridgeResult<void>.error(PromptBridgeFailure.denied);
  }
}

final class _CaptureTerminal implements Terminal {
  final lines = <String>[];

  @override
  void writeln([String? line]) => lines.add(line ?? '');

  @override
  Future<String> ask(String prompt) => Future<String>.value('');
}

void main() {
  test('the registry carries the admin without the remote-prompt opt-in',
      () {
    final registry = wasmEngineRegistry(
      remotePromptHost: _RecordingBridge(),
    );

    expect(registry.ids, contains(WasmPluginAdminPlugin.pluginId));
    expect(registry.ids, isNot(contains(RemotePromptPlugin.pluginId)),
        reason: 'the remote-prompt extension itself stays opt-in');
  });

  test('with the remote-prompt plugin selected, both plugins are carried',
      () {
    final registry = wasmEngineRegistry(
      remotePromptHost: _RecordingBridge(),
      includeRemotePromptPlugin: true,
    );

    expect(registry.ids, containsAll(
        [WasmPluginAdminPlugin.pluginId, RemotePromptPlugin.pluginId]));
  });

  test('a plain-session admin shows the tools and the section in the loop',
      () async {
    // The shape the registry factory builds when no artifact is selected
    // and no build seams are wired: a fresh lease book over the host
    // bridge, a plain terminal.
    final bridge = _RecordingBridge();
    final admin = WasmPluginAdminPlugin(
      manager: PluginManager(bridge: bridge),
      terminal: _CaptureTerminal(),
    );
    final provider = ScriptedProvider([scriptedReply('hi')]);
    final loop = AgentLoop(provider: provider, plugins: [admin]);
    loop.mountPlugin(admin);
    await loop.runTurn(Input('hello', id: 'u1'));

    final names =
        provider.requests.single.tools.map((tool) => tool.name).toSet();
    expect(names, containsAll(const [
      WasmPluginAdminPlugin.pluginBuildTool,
      WasmPluginAdminPlugin.pluginReloadTool,
      WasmPluginAdminPlugin.pluginStatusTool,
    ]));
    expect(provider.requests.single.systemPrompt,
        contains('<plugin-lifecycle>'));
    // Opt-in refusal semantics unchanged: mounting the admin alone never
    // opens a lease on the host bridge (plugin_reload reports
    // nothing-attached until an extension opens one).
    expect(bridge.opened, isEmpty);
    expect(admin.commands.map((command) => command.name), contains('plugins'));
  });
}
