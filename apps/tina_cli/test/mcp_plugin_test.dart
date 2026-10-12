import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_mcp/tina_mcp.dart';
import 'package:tina_mcp_tui/tina_mcp_tui.dart';
import 'package:tina_console/testing.dart';
import 'package:tina/src/console_catalog.dart';
import 'package:tina/session.dart';
import 'package:tina/tui.dart';
import 'app_test.dart' show FakeIo, fakeScreen;
import 'turn_rendering_test.dart' show waitFor;

void main() {
  late Directory root;
  late File config;
  setUp(() {
    root = Directory.systemTemp.createTempSync('tui-mcp-');
    config = File('${root.path}/global')
      ..writeAsStringSync('[default]\nmodel="scripted"\n');
  });
  tearDown(() => root.deleteSync(recursive: true));
  test('catalog creates independent MCP views over one configured runtime', () {
    final assembly = SessionAssembly.start(
      options: AssemblyOptions(
        configPath: config.path,
        workingDirectory: root.path,
        plugins: ['tina/mcp'],
      ),
      providerFactory: (_) => ScriptedProvider([]),
    );
    addTearDown(assembly.close);
    final runtime = assembly.host.plugins.whereType<McpPlugin>().single;
    expect(runtime, isNot(isA<ConsoleContribution>()));
    final first = createConsoleView(runtime) as McpView;
    final second = createConsoleView(runtime) as McpView;
    expect(first, isNot(same(second)));
    expect(first.mcp, same(second.mcp));
    expect(first.mcp, same(runtime.management));
  });
  test(
    'independent plugin saves merge into untouched tables while keeping settings drafts',
    () {
      final document = ConfigDocument.open(config.path);
      document.table('default')['model'] = 'draft-model';
      McpConfigStore(config.path).save(
        McpServerConfig('blender', {
          'command': 'blender-mcp',
          'enabled': false,
        }),
      );
      document.refreshUneditedTables();
      expect(document.table('default')['model'], 'draft-model');
      expect((document.table('mcp')['servers'] as Map).keys, ['blender']);
      document.save();
      expect(
        ConfigDocument.open(config.path).table('default')['model'],
        'draft-model',
      );
      expect(McpConfigStore(config.path).read().single.name, 'blender');
    },
  );
  test(
    'overlapping external edits remain stale and cannot overwrite a saved plugin config',
    () {
      final document = ConfigDocument.open(config.path);
      document.table('default')['model'] = 'draft-model';
      config.writeAsStringSync('[default]\nmodel="external-model"\n');
      document.refreshUneditedTables();
      expect(() => document.save(), throwsStateError);
      expect(
        ConfigDocument.open(config.path).table('default')['model'],
        'external-model',
      );
    },
  );
  test(
    'the registered plugin can connect, unload, clean up and reload between turns',
    () async {
      final library = await Isolate.resolvePackageUri(
        Uri.parse('package:tina_mcp/tina_mcp.dart'),
      );
      final fixture = library!
          .resolve('../test/fixtures/server.py')
          .toFilePath();
      McpConfigStore(config.path).save(
        McpServerConfig('fixture', {
          'command': 'python3',
          'args': [fixture],
        }),
      );
      final assembly = SessionAssembly.start(
        options: AssemblyOptions(
          configPath: config.path,
          workingDirectory: root.path,
          plugins: ['tina/mcp'],
        ),
        providerFactory: (_) =>
            ScriptedProvider(List.generate(5, (_) => scriptedReply('ok'))),
      );
      addTearDown(assembly.close);
      final original = assembly.host.plugins.whereType<McpPlugin>().single;
      await assembly.host.send('connect');
      expect(original.tools, hasLength(10));
      expect(
        assembly.pluginSettings.registry.definition('tina/mcp').description,
        contains('MCP servers'),
      );
      assembly.pluginSettings.apply(
        'tina/mcp',
        false,
        PluginScope.session,
        assembly.pluginManager,
      );
      expect(assembly.pluginManager.lastError, isNull);
      expect(assembly.host.plugins.whereType<McpPlugin>(), isEmpty);
      await original.shutdown();
      assembly.pluginSettings.apply(
        'tina/mcp',
        true,
        PluginScope.session,
        assembly.pluginManager,
      );
      final reloaded = assembly.host.plugins.whereType<McpPlugin>().single;
      expect(identical(original, reloaded), false);
      await assembly.host.send('reconnect');
      expect(reloaded.tools, hasLength(10));
      await reloaded.shutdown();
    },
  );
  test(
    'bad MCP configuration is rejected at startup with its table identified',
    () {
      expect(
        () => parseTinaConfig(
          jsonDecode('{"mcp":{"servers":{"bad":{"url":"file:///bad"}}}}'),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('mcp.servers.bad.url'),
          ),
        ),
      );
    },
  );

  for (final panels in [false, true]) {
    test(
      'settings view unloads and reloads with MCP (workspace: $panels)',
      () async {
        final library = await Isolate.resolvePackageUri(
          Uri.parse('package:tina_mcp/tina_mcp.dart'),
        );
        final fixture = library!
            .resolve('../test/fixtures/server.py')
            .toFilePath();
        McpConfigStore(config.path).save(
          McpServerConfig('fixture', {
            'command': 'python3',
            'args': [fixture],
          }),
        );
        final assembly = SessionAssembly.start(
          options: AssemblyOptions(
            configPath: config.path,
            workingDirectory: root.path,
            plugins: [
              'tina/mcp',
              'tina/chat-tui',
              if (panels) 'tina/panels-tui',
            ],
          ),
          providerFactory: (_) => ScriptedProvider([]),
        );
        final original = assembly.host.plugins.whereType<McpPlugin>().single;
        await assembly.host.send('connect');
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
        expect(visible(), contains('5 tools connected'));
        assembly.pluginSettings.apply(
          'tina/mcp',
          false,
          PluginScope.session,
          assembly.pluginManager,
        );
        expect(assembly.pluginManager.lastError, isNull);
        await original.shutdown();
        await waitFor(() => !visible().contains('Add local server (name)'));
        expect(assembly.host.plugins.whereType<McpPlugin>(), isEmpty);
        assembly.pluginSettings.apply(
          'tina/mcp',
          true,
          PluginScope.session,
          assembly.pluginManager,
        );
        expect(assembly.pluginManager.lastError, isNull);
        final restored = assembly.host.plugins.whereType<McpPlugin>().single;
        expect(restored, isNot(same(original)));
        expect(restored, isNot(isA<ConsoleContribution>()));
        await assembly.host.send('reconnect');
        expect(restored.tools, hasLength(10));
        io.feedBytes('MCP servers\r'.codeUnits);
        await waitFor(() => visible().contains('Add local server (name)'));
        expect(visible(), contains('5 tools connected'));
        editor.inject(EscapeKey());
        await waitFor(() => !visible().contains('Add local server (name)'));
        editor.inject(EscapeKey());
        await waitFor(
          () => panels
              ? editor.isEditing && !editor.isReadingKey
              : editor.pendingLine != null,
        );
        io.feedBytes('/quit\r'.codeUnits);
        expect(await done.timeout(const Duration(seconds: 3)), 0);
        await restored.shutdown();
      },
    );
  }
}
