/// The agent-facing lifecycle tools (commit 25): the three tool schemas
/// in the loop's snapshot, the single onPrompt section, and the
/// plugin_build/plugin_reload/plugin_status executors through a real
/// loop — the shared build flow's semantics are pinned in
/// tina_plugin_registry's build_flow_test; these pin the wiring.
library;

import 'package:tina_core/tina_core.dart' show Terminal;
import 'package:tina_engine_2/tina_engine_2.dart'
    show AgentLoop, CancelToken, Input, ScriptedProvider, ToolFinished,
        ToolUseBlock, TurnContext, scriptedReply;
import 'package:test/test.dart';
import 'package:tina_plugin_registry/build_flow.dart'
    show LocalConsentBook, LocalPluginBuild, PluginBuildException;
import 'package:tina_wasm/src/plugin_admin.dart';
import 'package:tina_wasm/src/plugin_manager.dart';
import 'package:tina_wasm/src/prompt_bridge_types.dart';

final class _RecordingBridge implements PromptPluginHostBridge {
  var _next = 1;
  final opened = <String>[];

  @override
  PromptBridgeResult<String> open() {
    final lease = 'lease-${_next++}';
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
    if (!opened.contains(lease)) {
      return const PromptBridgeResult<void>.error(PromptBridgeFailure.denied);
    }
    opened.remove(lease);
    return const PromptBridgeResult<void>.ok(null);
  }
}

final class _CaptureTerminal implements Terminal {
  final lines = <String>[];

  @override
  void writeln([String? line]) => lines.add(line ?? '');

  @override
  Future<String> ask(String prompt) => Future<String>.value('');
}

/// In-memory consent book: the hash-keyed semantics without a file.
final class _MemoryConsent implements LocalConsentBook {
  final remembered = <String>{};

  @override
  bool needsConsent(String hash) => !remembered.contains(hash);

  @override
  void remember(String hash) => remembered.add(hash);
}

LocalPluginBuild _buildOf(String hash) => LocalPluginBuild(
      name: 'my-plugin',
      version: 'local-${hash.substring(0, 12)}',
      hash: hash,
      componentPath: '/cache/my-plugin/component.wasm',
      builtAt: DateTime.utc(2026, 12, 1),
    );

void main() {
  late _RecordingBridge bridge;
  late PluginManager manager;
  late _CaptureTerminal terminal;

  setUp(() {
    bridge = _RecordingBridge();
    manager = PluginManager(bridge: bridge);
    terminal = _CaptureTerminal();
  });

  /// One loop with [admin] mounted, one turn whose scripted reply makes
  /// the model call [tool] with [input]; returns the finished results.
  Future<List<ToolFinished>> runToolCall(
    WasmPluginAdminPlugin admin,
    String tool,
    Map<String, dynamic> input, {
    String id = 'u1',
  }) async {
    final provider = ScriptedProvider([
      scriptedReply('',
          calls: [ToolUseBlock(id: 't-$id', name: tool, input: input)]),
      scriptedReply('done'),
    ]);
    final loop = AgentLoop(provider: provider, plugins: [admin]);
    loop.mountPlugin(admin);
    final finished = <ToolFinished>[];
    final sub = loop.toolActivity
        .listen((event) { if (event is ToolFinished) finished.add(event); });
    try {
      await loop.runTurn(Input('run $tool', id: id));
    } finally {
      await sub.cancel();
    }
    return finished;
  }

  test('the three tools appear in the loop snapshot with descriptions',
      () async {
    final admin = WasmPluginAdminPlugin(manager: manager, terminal: terminal);
    final provider = ScriptedProvider([scriptedReply('hi')]);
    final loop = AgentLoop(provider: provider, plugins: [admin]);
    loop.mountPlugin(admin);
    await loop.runTurn(Input('hello', id: 'u1'));

    final byName = {
      for (final tool in provider.requests.single.tools) tool.name: tool,
    };
    expect(byName, contains(WasmPluginAdminPlugin.pluginBuildTool));
    expect(byName, contains(WasmPluginAdminPlugin.pluginReloadTool));
    expect(byName, contains(WasmPluginAdminPlugin.pluginStatusTool));
    for (final name
        in const [WasmPluginAdminPlugin.pluginBuildTool, WasmPluginAdminPlugin.pluginReloadTool, WasmPluginAdminPlugin.pluginStatusTool]) {
      expect(byName[name]!.description, isNotEmpty, reason: name);
      expect(byName[name]!.inputSchema['type'], 'object', reason: name);
    }
    expect(byName[WasmPluginAdminPlugin.pluginBuildTool]!.inputSchema['required'],
        contains('source_dir'));
  });

  test('onPrompt adds exactly one lifecycle section', () {
    final admin = WasmPluginAdminPlugin(manager: manager, terminal: terminal);
    final context = TurnContext(
      CancelToken(),
      input: Input('x', id: 'x'),
      messages: [],
      promptSections: [],
      pinnedTools: [],
    );

    admin.onPrompt(context);

    expect(context.promptSections, hasLength(1));
    final text = context.promptSections.single;
    expect(text, startsWith('<plugin-lifecycle>'));
    for (final phrase in const [
      WasmPluginAdminPlugin.pluginBuildTool,
      WasmPluginAdminPlugin.pluginReloadTool,
      WasmPluginAdminPlugin.pluginStatusTool,
      'consent is asked once per artifact hash',
      'fresh plugin instance',
      'capability/policy gate',
      'not a general code-execution path',
    ]) {
      expect(text, contains(phrase));
    }
  });

  test('absent machinery adds nothing: no admin plugin, no section',
      () async {
    final provider = ScriptedProvider([scriptedReply('hi')]);
    final loop = AgentLoop(provider: provider, plugins: const []);
    await loop.runTurn(Input('hello', id: 'u1'));

    expect(provider.requests.single.systemPrompt,
        isNot(contains('<plugin-lifecycle>')));
  });

  test('plugin_build happy path: built, consented, reloaded', () async {
    manager.open();
    final consent = _MemoryConsent();
    var prompted = 0;
    final admin = WasmPluginAdminPlugin(
      manager: manager,
      terminal: terminal,
      buildArtifact: (sourcePath) async {
        expect(sourcePath, '/src/my-plugin');
        return _buildOf('a' * 64);
      },
      consent: consent,
      consentPrompt: (build) async {
        prompted++;
        return true;
      },
    );

    final finished = await runToolCall(admin, WasmPluginAdminPlugin.pluginBuildTool,
        <String, dynamic>{'source_dir': '/src/my-plugin'});

    expect(prompted, 1);
    expect(consent.remembered, contains('a' * 64));
    final result = finished.single.result;
    expect(result.isError, isFalse);
    expect(result.content, contains('built my-plugin local-aaaaaaaaaaaa'));
    expect(result.content, contains('origin local'));
    expect(result.content, contains('hash aaaaaaaaaaaa…'));
    expect(result.content, contains('reloaded: fresh store attached'));
    expect(result.content, contains('lease lease-2'));
    expect(result.content, contains('lifecycle=3'));
    expect(manager.status().reloads, 1);
  });

  test('plugin_build detached: installed, no reload', () async {
    final admin = WasmPluginAdminPlugin(
      manager: manager,
      terminal: terminal,
      buildArtifact: (sourcePath) async => _buildOf('b' * 64),
      consent: _MemoryConsent(),
      consentPrompt: (build) async => true,
    );

    final finished = await runToolCall(admin, WasmPluginAdminPlugin.pluginBuildTool,
        <String, dynamic>{'source_dir': '/src/my-plugin'});

    final result = finished.single.result;
    expect(result.isError, isFalse);
    expect(result.content, contains('plugin not attached'));
    expect(manager.status().reloads, 0);
  });

  test('plugin_build without the build seams reports the host-side path',
      () async {
    final admin = WasmPluginAdminPlugin(manager: manager, terminal: terminal);

    final finished = await runToolCall(admin, WasmPluginAdminPlugin.pluginBuildTool,
        <String, dynamic>{'source_dir': '/src/my-plugin'});

    final result = finished.single.result;
    expect(result.isError, isTrue);
    expect(result.content, contains('/plugins build /src/my-plugin'));
    expect(result.content, contains('tina plugin build'));
  });

  test('plugin_build without source_dir is refused', () async {
    final admin = WasmPluginAdminPlugin(manager: manager, terminal: terminal);

    final finished =
        await runToolCall(admin, WasmPluginAdminPlugin.pluginBuildTool, <String, dynamic>{});

    expect(finished.single.result.isError, isTrue);
    expect(finished.single.result.content, contains('source_dir'));
  });

  test('plugin_build missing toolchain: clean failure, no consent prompt',
      () async {
    var prompted = 0;
    final admin = WasmPluginAdminPlugin(
      manager: manager,
      terminal: terminal,
      buildArtifact: (sourcePath) async => throw const PluginBuildException(
          'no Dart SDK found on PATH — plugins build needs the dart '
          'executable to compile a wasm component'),
      consent: _MemoryConsent(),
      consentPrompt: (build) async {
        prompted++;
        return true;
      },
    );

    final finished = await runToolCall(admin, WasmPluginAdminPlugin.pluginBuildTool,
        <String, dynamic>{'source_dir': '/src/my-plugin'});

    expect(prompted, 0);
    final result = finished.single.result;
    expect(result.isError, isTrue);
    expect(result.content, contains('no Dart SDK found on PATH'));
    expect(manager.status().reloads, 0);
  });

  test('plugin_build compiler failure carries the compiler output',
      () async {
    final admin = WasmPluginAdminPlugin(
      manager: manager,
      terminal: terminal,
      buildArtifact: (sourcePath) async =>
          throw const PluginBuildException(
              'plugin compilation failed (exit 1)',
              stderr: 'Error: cannot resolve bin/main.dart'),
      consent: _MemoryConsent(),
      consentPrompt: (build) async => true,
    );

    final finished = await runToolCall(admin, WasmPluginAdminPlugin.pluginBuildTool,
        <String, dynamic>{'source_dir': '/src/my-plugin'});

    final result = finished.single.result;
    expect(result.isError, isTrue);
    expect(result.content, contains('plugin compilation failed'));
    expect(result.content, contains('Error: cannot resolve bin/main.dart'));
  });

  test('plugin_build consents once per hash, re-prompts on change',
      () async {
    final consent = _MemoryConsent();
    final prompts = <String>[];
    var builds = 0;
    final admin = WasmPluginAdminPlugin(
      manager: manager,
      terminal: terminal,
      buildArtifact: (sourcePath) async =>
          _buildOf(++builds == 3 ? 'd' * 64 : 'c' * 64),
      consent: consent,
      consentPrompt: (build) async {
        prompts.add(build.hash);
        return true;
      },
    );

    await runToolCall(admin, WasmPluginAdminPlugin.pluginBuildTool,
        <String, dynamic>{'source_dir': '/src/my-plugin'}, id: 'u1');
    await runToolCall(admin, WasmPluginAdminPlugin.pluginBuildTool,
        <String, dynamic>{'source_dir': '/src/my-plugin'}, id: 'u2');
    expect(prompts, hasLength(1),
        reason: 'the same hash consented once, not again');

    await runToolCall(admin, WasmPluginAdminPlugin.pluginBuildTool,
        <String, dynamic>{'source_dir': '/src/my-plugin'}, id: 'u3');
    expect(prompts, hasLength(2), reason: 'a changed hash re-prompts');
  });

  test('a declined consent keeps the old artifact attached', () async {
    final first = manager.open().valueOrThrow;
    final consent = _MemoryConsent();
    final admin = WasmPluginAdminPlugin(
      manager: manager,
      terminal: terminal,
      buildArtifact: (sourcePath) async => _buildOf('e' * 64),
      consent: consent,
      consentPrompt: (build) async => false,
    );

    final finished = await runToolCall(admin, WasmPluginAdminPlugin.pluginBuildTool,
        <String, dynamic>{'source_dir': '/src/my-plugin'});

    final result = finished.single.result;
    expect(result.isError, isTrue);
    expect(result.content, contains('consent declined'));
    expect(result.content, contains('previous artifact stays'));
    expect(manager.lease, first, reason: 'the old artifact stays attached');
    expect(manager.status().reloads, 0);
    expect(consent.remembered, isNot(contains('e' * 64)));
  });

  test('plugin_reload retires the lease and increments the counters',
      () async {
    final first = manager.open().valueOrThrow;
    final admin = WasmPluginAdminPlugin(manager: manager, terminal: terminal);

    final finished = await runToolCall(
        admin, WasmPluginAdminPlugin.pluginReloadTool, <String, dynamic>{});

    final result = finished.single.result;
    expect(result.isError, isFalse);
    expect(result.content, contains('reloaded'));
    expect(result.content, contains('lease lease-2'));
    expect(result.content, contains('lifecycle=3'));
    expect(result.content, contains('reloads=1'));
    expect(manager.lease, isNot(first));
  });

  test('plugin_reload while idle refuses without touching the bridge',
      () async {
    final admin = WasmPluginAdminPlugin(manager: manager, terminal: terminal);

    final finished = await runToolCall(
        admin, WasmPluginAdminPlugin.pluginReloadTool, <String, dynamic>{});

    expect(finished.single.result.isError, isTrue);
    expect(finished.single.result.content, contains('no wasm plugin attached'));
    expect(bridge.opened, isEmpty);
  });

  test('plugin_status reports origin, hash, timestamp and lease',
      () async {
    final lease = manager.open().valueOrThrow;
    final admin = WasmPluginAdminPlugin(
      manager: manager,
      terminal: terminal,
      artifact: const PluginArtifactOrigin(
        origin: 'local',
        hash: 'abcdef1234567890',
        builtAt: '2026-12-01T10:00:00Z',
      ),
    );

    final finished = await runToolCall(
        admin, WasmPluginAdminPlugin.pluginStatusTool, <String, dynamic>{});

    final text = finished.single.result.content;
    expect(text, contains('plugin tina/wasm-prompt: open'));
    expect(text, contains('lease $lease'));
    expect(text, contains('lifecycle=1 opens=1'));
    expect(text, contains('origin=local'));
    expect(text, contains('hash=abcdef1234567890'));
    expect(text, contains('built=2026-12-01T10:00:00Z'));
  });
}

extension on PromptBridgeResult<String> {
  String get valueOrThrow => switch (this) {
        PromptBridgeOk(value: final value) => value,
        PromptBridgeError(failure: final failure) => throw StateError(
            'expected a lease, got $failure',
          ),
      };
}
