// Repro for two reported gaps, checked at HEAD before any fix:
//
// 1. Escape inside the settings panel should close one submenu level, not the
//    whole panel, and must never cancel a request that is in flight.
// 2. MCP servers can be enabled/disabled from the settings panel.
//
// Drives the real assembly (McpPlugin.configured + McpView section) through
// the same runTui + FakeIo seams as mcp_plugin_test.dart.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_mcp/tina_mcp.dart';
import 'package:tina/tui.dart';

import 'app_test.dart' show FakeIo, fakeScreen;
import 'turn_rendering_test.dart' show waitFor;

void main() {
  late Directory root;
  late File config;
  setUp(() {
    root = Directory.systemTemp.createTempSync('mcp-settings-');
    config = File('${root.path}/global')
      ..writeAsStringSync('[default]\nmodel="scripted"\n');
  });
  tearDown(() => root.deleteSync(recursive: true));

  final enter = ControlKey(ControlCode.enter);
  final escape = EscapeKey();
  final space = CharInput(' ');
  final down = ArrowKey(ArrowDirection.down);

  test('settings panel toggles a configured MCP server off and on', () async {
    McpConfigStore(config.path).save(
      McpServerConfig('blender', {
        'command': 'blender-mcp',
        'enabled': true,
      }),
    );
    final assembly = SessionAssembly.start(
      options: AssemblyOptions(
        configPath: config.path,
        workingDirectory: root.path,
        plugins: ['tina/mcp', 'tina/chat-tui'],
      ),
      providerFactory: (_) => ScriptedProvider([]),
    );
    final io = FakeIo();
    final screen = fakeScreen(io);
    late LineEditor editor;
    final done = runTui(
      TuiSession.wrap(assembly),
      screen: screen,
      editorFor: (screen) =>
          editor = LineEditor(screen: screen, escapeTimeout: Duration.zero),
    );
    addTearDown(() async {
      assembly.close();
      io.feedBytes('\x03\x03\x03'.codeUnits);
      io.closeInput();
      await done.timeout(const Duration(seconds: 5));
    });
    String visible() {
      final terminal = VirtualTerminal(
        width: screen.layout.width,
        height: screen.layout.height,
      )..feed(io.written.toString());
      return List.generate(
        screen.layout.height,
        terminal.rowText,
      ).join('\n');
    }

    await waitFor(() => editor.isEditing);
    io.feedBytes('/settings\r'.codeUnits);
    await waitFor(() => editor.isReadingKey);
    io.feedBytes('MCP servers\r'.codeUnits);
    await waitFor(() => visible().contains('Add local server (name)'));
    // The compact row shows the label left, the toggle value right.
    expect(visible(), contains(RegExp(r'blender\s+On')),
        reason: 'the blender toggle must be visible with its current value');

    // Toggle blender off: move past the two add-server rows to the toggle.
    editor.inject(down);
    editor.inject(down);
    editor.inject(space);
    final off = RegExp(r'blender\s+Off');
    final scopeChoice = 'choose a supported scope';
    await waitFor(() =>
        visible().contains(off) || visible().contains(scopeChoice));
    if (visible().contains(scopeChoice)) {
      editor.inject(enter); // Edit global
      editor.inject(space); // now actually toggle
      await waitFor(() => visible().contains(off));
    }
    final stored = McpConfigStore(config.path).read();
    expect(stored.single.enabled, isFalse,
        reason: 'space on the toggle row must persist enabled=false');

    // Toggle back on. Selection survives the section rebuild, so the same
    // row stays armed — no re-navigation needed.
    editor.inject(space);
    await waitFor(() => visible().contains(RegExp(r'blender\s+On')));
    expect(McpConfigStore(config.path).read().single.enabled, isTrue);

    // Esc closes the submenu (back to the settings root), not the panel.
    editor.inject(escape);
    try {
      await waitFor(() => visible().contains('Settings'));
    } catch (_) {
      // ignore: avoid_print
      print('--- visible after escape from MCP submenu ---\n${visible()}');
      rethrow;
    }
    expect(visible(), isNot(contains('Add local server (name)')),
        reason: 'Esc leaves the MCP submenu but keeps the panel open');
    editor.inject(escape);
    try {
      // The closing toast says "Settings closed." — check the dialog frame
      // itself is gone instead of the substring.
      await waitFor(() => !visible().contains('┌ Settings'));
    } catch (_) {
      // ignore: avoid_print
      print('--- visible after second escape (panel should be closed) ---\n${visible()}');
      rethrow;
    }
    io.feedBytes('/quit\r'.codeUnits);
    expect(await done.timeout(const Duration(seconds: 3)), 0);
  });
}
