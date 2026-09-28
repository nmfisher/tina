import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tui/tina_tui.dart';
import 'app_test.dart' show FakeIo, fakeScreen;

final class LivePanel extends AgentPlugin implements ConsoleContribution {
  @override
  String get id => 'acme/panel';
  int attached = 0, detached = 0, repaints = 0;
  @override
  void attachConsole(ConsoleContext context) {
    attached++;
  }

  @override
  void detachConsole() {
    detached++;
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
    expect(app.commands['panel'], isNotNull);
    resizes.add(ScreenLayout.fromSize(40, 8, split: false));
    await Future<void>.delayed(Duration.zero);
    final paints = instances.single.repaints;
    expect(paints, greaterThan(0));
    await app.handleCommand('/plugins disable acme/panel');
    expect(instances.single.detached, 1);
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
}
