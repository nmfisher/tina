import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina/session.dart';
import 'package:tina/tui.dart';
import 'package:tina/src/console_catalog.dart';
import 'app_test.dart' show FakeIo, fakeScreen;

final class PanelPlugin extends AgentPlugin {
  @override
  String get id => 'acme/panel';

  @override
  List<Command> get commands =>
      [Command(name: 'panel', description: 'panel', handler: (_) {})];
}

final class LivePanel implements ConsoleContribution {
  LivePanel({this.fail = false});
  final bool fail;
  late ConsoleContext context;
  String get id => 'acme/panel';
  int attached = 0, detached = 0, repaints = 0;
  @override
  void attachConsole(ConsoleContext context) {
    this.context = context;
    attached++;
    context.settings
        .registerSection(id: id, title: 'Live panel', build: () => []);
    if (fail) {
      context.bindPrompt(() => 'broken > ');
      throw StateError('fixture attachment failure');
    }
  }

  @override
  void detachConsole() {
    detached++;
    if (fail) throw StateError('fixture teardown failure');
  }

  @override
  void repaintConsole() {
    repaints++;
  }
}

void main() {
  test('explicit factories keep views and client authority independent', () {
    final root = Directory.systemTemp.createTempSync('explicit-view-factory-');
    addTearDown(() => root.deleteSync(recursive: true));
    final assembly = SessionAssembly.start(
        options: AssemblyOptions(
            configPath: '${root.path}/config',
            workingDirectory: root.path,
            plugins: ['acme/panel']),
        providerFactory: (_) => ScriptedProvider([]),
        registerPlugins: (registry) => registry.register(
            'acme/panel', (_) => PanelPlugin(),
            live: true, description: 'Test plugin registration.'));
    final instances = <LivePanel>[];
    final accessByView = <ClientAccess>[];
    final session =
        TuiSession.wrap(assembly, viewFactory: (plugin, {required access}) {
      if (plugin is PanelPlugin) {
        final view = LivePanel();
        instances.add(view);
        accessByView.add(access);
        return view;
      }
      return createConsoleView(plugin, access: access);
    });
    addTearDown(session.shutdown);
    final views = [
      session.createView(),
      session.createView(role: SessionRole.observer)
    ];
    final inputs = [FakeIo(), FakeIo()];
    final screens = inputs.map(fakeScreen).toList();
    final editors = [for (final screen in screens) LineEditor(screen: screen)];
    addTearDown(() {
      for (final view in views) view.close();
      for (final editor in editors) editor.close(reportLatency: false);
      for (final screen in screens) screen.dispose();
      for (final input in inputs) input.closeInput();
    });
    for (var i = 0; i < views.length; i++) {
      views[i].attachConsole(
          ConsoleContext(screen: screens[i], editor: editors[i]));
    }
    expect(assembly.host.plugins.whereType<PanelPlugin>(), hasLength(1));
    expect(instances, hasLength(2));
    expect(instances.first, isNot(same(instances.last)));
    expect(accessByView.first, same(views.first.connection.access));
    expect(accessByView.last, same(views.last.connection.access));
    expect(accessByView.first.canControl, isTrue);
    expect(accessByView.last.canControl, isFalse);
    views.first.close();
    expect(instances.first.detached, 1);
    expect(instances.first.context.settings.sections, isEmpty);
    expect(instances.last.detached, 0);
    expect(instances.last.context.settings.sections.single.id, 'acme/panel');
    expect(assembly.commands['panel'], isNotNull);
  });

  test(
      'a live UI plugin attaches, resizes, detaches and reloads through plugin settings',
      () async {
    final root = Directory.systemTemp.createTempSync('live-plugin-ui-');
    addTearDown(() => root.deleteSync(recursive: true));
    final io = FakeIo();
    final resizes = StreamController<ScreenLayout>();
    final instances = <LivePanel>[];
    final app = SessionAssembly.start(
        options: AssemblyOptions(
            configPath: '${root.path}/global',
            workingDirectory: root.path,
            plugins: []),
        providerFactory: (_) => ScriptedProvider([]),
        registerPlugins: (registry) => registry.register(
            'acme/panel', (_) => PanelPlugin(),
            live: true, description: 'Test plugin registration.'));
    final session =
        TuiSession.wrap(app, viewFactory: (plugin, {required access}) {
      if (plugin is PanelPlugin) {
        final view = LivePanel();
        instances.add(view);
        return view;
      }
      return createConsoleView(plugin, access: access);
    });
    final done =
        runTui(session, screen: fakeScreen(io), resizes: resizes.stream);
    app.pluginSettings
        .apply('acme/panel', true, PluginScope.session, app.pluginManager);
    expect(instances.single.attached, 1);
    expect(instances.single.context.settings.sections.single.id, 'acme/panel');
    expect(app.commands['panel'], isNotNull);
    resizes.add(ScreenLayout.fromSize(40, 8, split: false));
    await Future<void>.delayed(Duration.zero);
    final paints = instances.single.repaints;
    expect(paints, greaterThan(0));
    app.pluginSettings
        .apply('acme/panel', false, PluginScope.session, app.pluginManager);
    expect(instances.single.detached, 1);
    expect(instances.single.context.settings.sections, isEmpty);
    expect(app.commands['panel'], isNull);
    resizes.add(ScreenLayout.fromSize(80, 24, split: false));
    await Future<void>.delayed(Duration.zero);
    expect(instances.single.repaints, paints);
    app.pluginSettings
        .apply('acme/panel', true, PluginScope.session, app.pluginManager);
    expect(instances, hasLength(2));
    expect(instances.last.attached, 1);
    io.feedBytes('/quit\r'.codeUnits);
    expect(await done, 0);
    expect(instances.last.detached, 1);
    await resizes.close();
    io.closeInput();
  });

  for (final panels in [false, true]) {
    test('live attachment rollback and reload (workspace: $panels)', () async {
      final root = Directory.systemTemp.createTempSync('failed-live-ui-');
      addTearDown(() => root.deleteSync(recursive: true));
      final io = FakeIo();
      final instances = <LivePanel>[];
      var failAttach = true;
      final assembly = SessionAssembly.start(
          options: AssemblyOptions(
              configPath: '${root.path}/config',
              workingDirectory: root.path,
              plugins: [if (panels) 'tina/panels-tui']),
          providerFactory: (_) => ScriptedProvider([]),
          registerPlugins: (registry) => registry.register(
              'acme/panel', (_) => PanelPlugin(),
              live: true, description: 'Test plugin registration.'));
      final session =
          TuiSession.wrap(assembly, viewFactory: (plugin, {required access}) {
        if (plugin is PanelPlugin) {
          final view = LivePanel(fail: failAttach);
          instances.add(view);
          return view;
        }
        return createConsoleView(plugin, access: access);
      });
      final done = runTui(session, screen: fakeScreen(io));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      assembly.pluginSettings.apply(
          'acme/panel', true, PluginScope.session, assembly.pluginManager);
      expect(assembly.pluginManager.lastError,
          contains('fixture attachment failure'));
      expect(assembly.commands['panel'], isNull);
      expect(instances.single.detached, 1);
      expect(instances.single.context.settings.sections, isEmpty);
      expect(instances.single.context.input.promptBuilder, isNull);
      failAttach = false;
      assembly.pluginSettings.apply(
          'acme/panel', true, PluginScope.session, assembly.pluginManager);
      expect(assembly.pluginManager.lastError, isNull);
      expect(instances.last.context.settings.sections.single.id, 'acme/panel');
      assembly.pluginSettings.apply(
          'acme/panel', false, PluginScope.session, assembly.pluginManager);
      expect(instances.last.context.settings.sections, isEmpty);
      io.feedBytes('/quit\r'.codeUnits);
      expect(await done, 0);
      io.closeInput();
    });
  }
}
