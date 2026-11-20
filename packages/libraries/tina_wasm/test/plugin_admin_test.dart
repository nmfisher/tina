import 'package:tina_core/tina_core.dart' show Command, Terminal;
import 'package:test/test.dart';
import 'package:tina_wasm/src/plugin_admin.dart';
import 'package:tina_wasm/src/plugin_manager.dart';
import 'package:tina_wasm/src/prompt_bridge_types.dart';

final class _RecordingBridge implements PromptPluginHostBridge {
  var _next = 1;
  final opened = <String>[];
  final retired = <String>[];
  bool failClose = false;

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
    if (!opened.contains(lease)) {
      return const PromptBridgeResult<String>.error(
        PromptBridgeFailure.denied,
      );
    }
    return PromptBridgeResult<String>.ok('session=$sessionId model=$model');
  }

  @override
  PromptBridgeResult<void> close({required String lease}) {
    if (failClose) {
      return const PromptBridgeResult<void>.error(PromptBridgeFailure.failed);
    }
    if (!opened.contains(lease)) {
      return const PromptBridgeResult<void>.error(PromptBridgeFailure.denied);
    }
    opened.remove(lease);
    retired.add(lease);
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

void main() {
  late _RecordingBridge bridge;
  late PluginManager manager;
  late WasmPluginAdminPlugin admin;
  late _CaptureTerminal terminal;

  setUp(() {
    bridge = _RecordingBridge();
    manager = PluginManager(bridge: bridge);
    terminal = _CaptureTerminal();
    admin = WasmPluginAdminPlugin(manager: manager, terminal: terminal);
  });

  Command command() => admin.commands.singleWhere((c) => c.name == 'plugins');

  test('status view reports the lease book, empty argument', () async {
    await command().handler('');
    expect(terminal.lines, hasLength(2));
    expect(terminal.lines[0], contains('plugin tina/wasm-prompt: closed'));
    expect(terminal.lines[1], contains('lifecycle=0'));
    expect(terminal.lines[1], contains('lastFailure=none'));
  });

  test("the 'status' word behaves like the empty argument", () async {
    await command().handler('status');
    expect(terminal.lines[0], contains('closed'));
  });

  test('status view shows the open lease after a mount', () async {
    manager.open();
    await command().handler('');
    expect(terminal.lines[0], contains('open'));
    expect(terminal.lines[0], contains(manager.lease!));
    expect(terminal.lines[1], contains('opens=1'));
  });

  test('reload while idle is refused without touching the bridge', () async {
    await command().handler('reload');
    expect(terminal.lines.single, contains('no wasm plugin attached'));
    expect(bridge.opened, isEmpty);
  });

  test('reload retires the live lease and attaches a fresh store', () async {
    final first = manager.open().valueOrThrow();
    await command().handler('reload');
    final second = manager.lease!;
    expect(second, isNot(first));
    expect(bridge.retired, [first]);
    expect(terminal.lines.single, contains('reloaded'));
    expect(terminal.lines.single, contains('lifecycle=3'));
    expect(manager.status().reloads, 1);
  });

  test('a transient close failure is reported and keeps the lease', () async {
    manager.open();
    bridge.failClose = true;
    await command().handler('reload');
    expect(terminal.lines.single, contains('plugin reload failed: failed'));
    // No second lease was stacked on the live one.
    expect(manager.isOpen, isTrue);
    expect(manager.status().reloads, 0);
  });

  test('an unknown word explains the argument vocabulary', () async {
    await command().handler('detach');
    expect(terminal.lines.single, contains('unknown /plugins argument'));
  });

  test('completion offers build and reload', () async {
    expect(await command().complete!(''), ['build', 'reload']);
    expect(await command().complete!('re'), ['reload']);
    expect(await command().complete!('status'), isEmpty);
  });
  test('status reports the artifact origin, hash and build time', () async {
    final terminal = _CaptureTerminal();
    final admin = WasmPluginAdminPlugin(
      manager: manager,
      terminal: terminal,
      artifact: const PluginArtifactOrigin(
        origin: 'local',
        hash: 'abcdef1234567890',
        builtAt: '2026-12-01T10:00:00Z',
      ),
    );
    await admin.commands.single.handler('status');
    final text = terminal.lines.join('\n');
    expect(text, contains('origin=local'));
    expect(text, contains('hash=abcdef1234567890'));
    expect(text, contains('built=2026-12-01T10:00:00Z'));

    // Without artifact info, status stays exactly as it was.
    terminal.lines.clear();
    final plain = WasmPluginAdminPlugin(manager: manager, terminal: terminal);
    await plain.commands.single.handler('');
    expect(terminal.lines.join('\n'), isNot(contains('origin=')));
  });

  test('build explains the host-side path; completion offers it', () async {
    final terminal = _CaptureTerminal();
    final admin = WasmPluginAdminPlugin(manager: manager, terminal: terminal);
    await admin.commands.single.handler('build');
    expect(terminal.lines.single, contains('front end'));
    expect(terminal.lines.single, contains('tina plugin build'));
    expect(await admin.commands.single.complete!(''), contains('build'));
    expect(await admin.commands.single.complete!('bu'), ['build']);
  });
}

extension on PromptBridgeResult<String> {
  String valueOrThrow() => switch (this) {
    PromptBridgeOk(value: final value) => value,
    PromptBridgeError(failure: final failure) => throw StateError(
      'expected a lease, got $failure',
    ),
  };

}
