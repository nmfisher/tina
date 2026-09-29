import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tui/tina_tui.dart';
import 'app_test.dart' show FakeIo, fakeScreen;

final class LivePanel extends AgentPlugin implements ConsoleContribution {
  LivePanel({this.fail = false});
  final bool fail;
  late ConsoleContext context;
  @override
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

  @override
  List<Command> get commands =>
      [Command(name: 'panel', description: 'panel', handler: (_) {})];
}

void main() {
  test(
      'a live UI plugin attaches, resizes, detaches and reloads through /plugins',
      () async {
    final root = Directory.systemTemp.createTempSync('live-plugin-ui-');
    addTearDown(() => root.deleteSync(recursive: true));
    final io = FakeIo();
    final resizes = StreamController<ScreenLayout>();
    final instances = <LivePanel>[];
    final app = TuiAssembly.start(
        options: AssemblyOptions(
            configPath: '${root.path}/global',
            workingDirectory: root.path,
            plugins: []),
        providerFactory: (_) => ScriptedProvider([]),
        registerPlugins: (registry) => registry.register('acme/panel', (_) {
              final panel = LivePanel();
              instances.add(panel);
              return panel;
            }, live: true));
    final done = runApp(TuiSession.wrap(app),
        screen: fakeScreen(io), resizes: resizes.stream);
    await app.handleCommand('/plugins enable acme/panel');
    expect(instances.single.attached, 1);
    expect(instances.single.context.settings.sections.single.id, 'acme/panel');
    expect(app.commands['panel'], isNotNull);
    resizes.add(ScreenLayout.fromSize(40, 8, split: false));
    await Future<void>.delayed(Duration.zero);
    final paints = instances.single.repaints;
    expect(paints, greaterThan(0));
    await app.handleCommand('/plugins disable acme/panel');
    expect(instances.single.detached, 1);
    expect(instances.single.context.settings.sections, isEmpty);
    expect(app.commands['panel'], isNull);
    resizes.add(ScreenLayout.fromSize(80, 24, split: false));
    await Future<void>.delayed(Duration.zero);
    expect(instances.single.repaints, paints);
    await app.handleCommand('/plugins enable acme/panel');
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
      final assembly = TuiAssembly.start(
          options: AssemblyOptions(
              configPath: '${root.path}/config',
              workingDirectory: root.path,
              plugins: [if (panels) 'tina/panels-tui']),
          providerFactory: (_) => ScriptedProvider([]),
          registerPlugins: (registry) => registry.register('acme/panel', (_) {
                final plugin = LivePanel(fail: failAttach);
                instances.add(plugin);
                return plugin;
              }, live: true));
      final done = runApp(TuiSession.wrap(assembly), screen: fakeScreen(io));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await assembly.handleCommand('/plugins enable acme/panel');
      expect(assembly.pluginManager.lastError,
          contains('fixture attachment failure'));
      expect(assembly.commands['panel'], isNull);
      expect(instances.single.detached, 1);
      expect(instances.single.context.settings.sections, isEmpty);
      expect(instances.single.context.input.promptBuilder, isNull);
      failAttach = false;
      await assembly.handleCommand('/plugins enable acme/panel');
      expect(assembly.pluginManager.lastError, isNull);
      expect(instances.last.context.settings.sections.single.id, 'acme/panel');
      await assembly.handleCommand('/plugins disable acme/panel');
      expect(instances.last.context.settings.sections, isEmpty);
      io.feedBytes('/quit\r'.codeUnits);
      expect(await done, 0);
      io.closeInput();
    });
  }
}
