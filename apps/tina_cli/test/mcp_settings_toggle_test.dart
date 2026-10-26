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
    // MCP is now a top-level category (no Permissions detour).
    io.feedBytes('MCP\r'.codeUnits);
    await waitFor(() => visible().contains('Add local server (name)'));
    // The compact row shows the label left, the toggle value right.
    expect(visible(), contains(RegExp(r'blender\s+On')),
        reason: 'the blender row must be visible with its current state');

    // Enter opens the server's details submenu; Space toggles Enabled.
    editor.inject(down); // past the two add-server rows to blender
    editor.inject(down);
    editor.inject(enter);
    await waitFor(() => visible().contains(RegExp(r'Enabled\s+On')));
    editor.inject(space);
    final off = RegExp(r'Enabled\s+Off');
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
        reason: 'space on the Enabled row must persist enabled=false');

    // Toggle back on. The details menu stays open and the toggle row stays
    // armed, so the same keypress position toggles again.
    editor.inject(space);
    await waitFor(() => visible().contains(RegExp(r'Enabled\s+On')));
    expect(McpConfigStore(config.path).read().single.enabled, isTrue);

    // Esc closes the details submenu (back to the MCP server list), then the
    // second Esc leaves the category, the third closes the panel.
    editor.inject(escape);
    try {
      await waitFor(() => visible().contains('Add local server (name)'));
    } catch (_) {
      // ignore: avoid_print
      print('--- visible after escape from server details ---\n${visible()}');
      rethrow;
    }
    expect(visible(), contains('blender'),
        reason: 'Esc leaves the details submenu but keeps the MCP list open');
    editor.inject(escape);
    editor.inject(escape);
    try {
      // The closing toast says "Settings closed." — check the dialog frame
      // itself is gone instead of the substring.
      await waitFor(() => !visible().contains('┌ Settings'));
    } catch (_) {
      // ignore: avoid_print
      print('--- visible after final escapes (panel should be closed) ---\n${visible()}');
      rethrow;
    }
    io.feedBytes('/quit\r'.codeUnits);
    expect(await done.timeout(const Duration(seconds: 3)), 0);
  });
}
