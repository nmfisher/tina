import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_mcp/tina_mcp.dart';
import 'package:tina_tui/tina_tui.dart';
import 'package:tina_tui/src/mcp_console_plugin.dart';
import 'app_test.dart' show FakeIo, fakeScreen;

void main() {
  late Directory root;
  late File config;
  setUp(() {
    root = Directory.systemTemp.createTempSync('tui-mcp-');
    config = File('${root.path}/global')
      ..writeAsStringSync('[default]\nmodel="scripted"\n');
  });
  tearDown(() => root.deleteSync(recursive: true));
  test('MCP settings attachment offers checkbox and fields; detach releases it',
      () async {
    final io = FakeIo();
    final screen = fakeScreen(io);
    final editor = LineEditor(screen: screen);
    addTearDown(() {
      editor.close();
      screen.dispose();
      io.closeInput();
    });
    final context = ConsoleContext(screen: screen, editor: editor);
    final store = McpConfigStore(config.path);
    final plugin = McpConsolePlugin(
        store: store,
        workingDirectory: root.path,
        approve: (
                {required operation,
                required target,
                required reason,
                context = const {}}) async =>
            throw StateError('Should not launch a server while editing'));
    addTearDown(plugin.shutdown);
    final attachment = ConsoleAttachment.attach(plugin, context);
    final section = context.settings.sections.single;
    final add = section
        .build()
        .whereType<SettingText>()
        .singleWhere((c) => c.id == 'add_server');
    await add.change('blender');
    expect(store.read().single.command, 'blender-mcp');
    expect(store.read().single.enabled, false);
    final fields = section.build();
    final checkbox = fields.whereType<SettingToggle>().single;
    await checkbox.change(true);
    expect(store.read().single.enabled, true);
    final command = section
        .build()
        .whereType<SettingText>()
        .singleWhere((c) => c.id == 'blender/command');
    await command.change('/path/to/official/blender-mcp');
    expect(store.read().single.command, '/path/to/official/blender-mcp');
    final timeout = section
        .build()
        .whereType<SettingText>()
        .singleWhere((c) => c.id == 'blender/timeout_ms');
    expect(timeout.read(), '60,000');
    await timeout.change('120,000');
    expect(store.read().single.timeout!.inMilliseconds, 120000);
    final env = section
        .build()
        .whereType<SettingText>()
        .singleWhere((c) => c.id == 'blender/env');
    expect(env.secret, true);
    attachment.dispose();
    expect(context.settings.sections, isEmpty);
  });
  test(
      'independent plugin saves merge into untouched tables while keeping settings drafts',
      () {
    final document = ConfigDocument.open(config.path);
    document.table('default')['model'] = 'draft-model';
    McpConfigStore(config.path).save(McpServerConfig(
        'blender', {'command': 'blender-mcp', 'enabled': false}));
    document.refreshUneditedTables();
    expect(document.table('default')['model'], 'draft-model');
    expect((document.table('mcp')['servers'] as Map).keys, ['blender']);
    document.save();
    expect(ConfigDocument.open(config.path).table('default')['model'],
        'draft-model');
    expect(McpConfigStore(config.path).read().single.name, 'blender');
  });
  test(
      'overlapping external edits remain stale and cannot overwrite a saved plugin config',
      () {
    final document = ConfigDocument.open(config.path);
    document.table('default')['model'] = 'draft-model';
    config.writeAsStringSync('[default]\nmodel="external-model"\n');
    document.refreshUneditedTables();
    expect(() => document.save(), throwsStateError);
    expect(ConfigDocument.open(config.path).table('default')['model'],
        'external-model');
  });
  test(
      'the registered plugin can connect, unload, clean up and reload between turns',
      () async {
    final library = await Isolate.resolvePackageUri(
        Uri.parse('package:tina_mcp/tina_mcp.dart'));
    final fixture = library!.resolve('../test/fixtures/server.py').toFilePath();
    McpConfigStore(config.path).save(McpServerConfig('fixture', {
      'command': 'python3',
      'args': [fixture]
    }));
    final assembly = TuiAssembly.start(
        options: AssemblyOptions(
            configPath: config.path,
            workingDirectory: root.path,
            plugins: ['tina/mcp']),
        providerFactory: (_) =>
            ScriptedProvider(List.generate(5, (_) => scriptedReply('ok'))));
    addTearDown(assembly.close);
    final original = assembly.host.plugins.whereType<McpPlugin>().single;
    await assembly.host.send('connect');
    expect(original.tools, hasLength(10));
    expect(assembly.pluginSettings.registry.definition('tina/mcp').description,
        contains('MCP servers'));
    assembly.pluginSettings
        .apply('tina/mcp', false, PluginScope.session, assembly.pluginManager);
    expect(assembly.pluginManager.lastError, isNull);
    expect(assembly.host.plugins.whereType<McpPlugin>(), isEmpty);
    await original.shutdown();
    assembly.pluginSettings
        .apply('tina/mcp', true, PluginScope.session, assembly.pluginManager);
    final reloaded = assembly.host.plugins.whereType<McpPlugin>().single;
    expect(identical(original, reloaded), false);
    await assembly.host.send('reconnect');
    expect(reloaded.tools, hasLength(10));
    await reloaded.shutdown();
  });
  test('bad MCP configuration is rejected at startup with its table identified',
      () {
    expect(
        () => parseTinaConfig(
            jsonDecode('{"mcp":{"servers":{"bad":{"url":"file:///bad"}}}}')),
        throwsA(isA<FormatException>().having(
            (e) => e.message, 'message', contains('mcp.servers.bad.url'))));
  });
}
