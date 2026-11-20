/// The cross-leg regression suite (commit 28, owner directive): the
/// native catalog boots, every former cast site's factory runs, and
/// the settings open path completes — all with a WASM-SHAPED tools
/// payload (`WasmShapedToolsPlugin`, exactly the surfaces the wasm
/// leg's `PortableToolsPlugin` implements). The live failure
/// ('PortableToolsPlugin is not a subtype of ToolsPlugin in type
/// cast', wasm settings open) existed because every test environment
/// held a native ToolsPlugin where production-wasm holds the portable
/// one. This suite pins the other leg in plain `dart test`.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_mode/tina_mode.dart';
import 'package:tina_tools/portable_tools.dart' show ToolsPluginSurface;
import 'package:tina_tools/testing.dart';

import 'package:tina/src/tools_factory.dart' show injectedToolsPluginFactory;
import 'package:tina/src/tui_presentation.dart' show presentationForAssembly;
import 'package:tina/session.dart';

import 'app_test.dart' show FakeIo;

void main() {
  late Directory root;
  late File config;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tina-cross-leg-');
    // The empty [plugins] enabled list keeps the config layer from
    // selecting a second approval-channel provider alongside the
    // session baseline below (the panel test uses the same shape).
    config = File('${root.path}/config')
      ..writeAsStringSync(
          '[default]\nmodel = "scripted"\n[plugins]\nenabled=[]\n');
  });

  tearDown(() {
    injectedToolsPluginFactory = null;
    root.deleteSync(recursive: true);
  });

  test(
      'the whole catalog builds, and settings open, with a wasm-shaped '
      'tools payload', () async {
    // The wasm leg's shape: ModePolicySource, ToolSessionSource and
    // ToolsPluginSurface — and deliberately NOT the native ToolsPlugin.
    final wasmShaped = WasmShapedToolsPlugin();
    injectedToolsPluginFactory = (_) => wasmShaped;

    // The default session set plus the plugins whose factories carry
    // the former cast sites (one capability per provider — enabling
    // every id would select two approval channels).
    final app = SessionAssembly.start(
      providerFactory: (_) => ScriptedProvider([]),
      options: AssemblyOptions(
        configPath: config.path,
        workingDirectory: root.path,
        // A real session's shape (one provider per capability) plus the
        // plugins whose factories carry the former cast sites.
        plugins: const [
          'tina/system-instruction',
          'tina/providers',
          'tina/mode',
          'tina/tools',
          // The approval channel follows the config default
          // (approvals-tui); naming a second channel provider would be
          // a capability conflict.
          'tina/session-controls',
          'tina/chat-tui',
          'tina/grok-guard',
          'tina/token-rate-tui',
          'tina/activity-tui',
          'tina/tasks',
          'tina/context',
          'tina/context-tui',
          'tina/persistence',
          'tina/memory',
        ],
      ),
    );
    addTearDown(app.close);

    // The payload IS the wasm-shaped stub, and the capability queries
    // resolve it — typed access, never a cast.
    expect(app.tools, same(wasmShaped));
    expect(app.capability<ToolsPluginSurface>(), same(wasmShaped));
    expect(app.capability<ModePolicySource>()!.modePolicy,
        same(wasmShaped.modePolicy),
        reason: 'surface delegation reaches the stub\'s real mode policy');

    // The settings open path — the live failure site: constructed and
    // driven exactly as the TUI drives it, over a fake ANSI console.
    final io = FakeIo();
    final screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(100, 24, split: false),
    );
    final editor = LineEditor(screen: screen);
    final presentation =
        presentationForAssembly(app, connection: app.host.connect());
    final settings = presentation
        .settingsFor(ConsoleContext(screen: screen, editor: editor));

    final opened = settings.open();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    settings.close();
    final message = await opened.timeout(const Duration(seconds: 10));

    expect(message, anyOf('Settings closed.', contains('Settings closed')),
        reason: 'no type-cast failure; the panel opened and closed');
    editor.close();
    screen.dispose();
  });

  test('native behavior is unchanged: the native payload still resolves',
      () async {
    // No injected factory: the platform default (the full native
    // ToolsPlugin) builds, and the same queries answer it.
    final app = SessionAssembly.start(
      providerFactory: (_) => ScriptedProvider([]),
      options: AssemblyOptions(
        configPath: config.path,
        workingDirectory: root.path,
      ),
    );
    addTearDown(app.close);

    expect(app.tools, isA<ToolsPluginSurface>());
    expect(app.capability<ToolsPluginSurface>(), same(app.tools));
    expect(app.capability<ModePolicySource>(), same(app.tools));
  });
}
