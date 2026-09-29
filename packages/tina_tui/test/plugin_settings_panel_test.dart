import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tui/tina_tui.dart';
import 'app_test.dart' show FakeIo, fakeScreen;

void main() {
  late Directory root;
  late File config;
  late TuiAssembly app;
  setUp(() {
    root = Directory.systemTemp.createTempSync('plugin-checkboxes-');
    config = File('${root.path}/global')
      ..writeAsStringSync(
          '[default]\nmodel="scripted"\n[plugins]\nenabled=[]\n');
    app = TuiAssembly.start(
        options: AssemblyOptions(
            configPath: config.path, workingDirectory: root.path),
        providerFactory: (_) => ScriptedProvider([]));
  });
  tearDown(() {
    app.close();
    root.deleteSync(recursive: true);
  });
  final enter = ControlKey(ControlCode.enter);
  final escape = EscapeKey();
  final space = CharInput(' ');
  final reset = ControlKey(ControlCode.ctrlR);
  final down = ArrowKey(ArrowDirection.down);

  Future<String> drive(List<Object> steps) async {
    final io = FakeIo();
    final screen = fakeScreen(io);
    final editor = LineEditor(screen: screen);
    var index = 0;
    late SettingsPanel panel;
    panel = SettingsPanel(screen, editor, readEvent: () async {
      while (index < steps.length && steps[index] is void Function()) {
        (steps[index++] as void Function())();
      }
      if (index >= steps.length) fail('unexpected key read');
      screen.resize(
          ScreenLayout.fromSize(index.isEven ? 40 : 100, 8, split: false));
      panel.repaint();
      return steps[index++] as InputEvent;
    });
    try {
      await panel.run(
          path: config.path,
          pluginIds: app.pluginSettings.registry.ids,
          pluginSettings: app.pluginSettings,
          pluginManager: app.pluginManager);
      expect(index, steps.length);
      return io.written.toString();
    } finally {
      editor.close();
      screen.dispose();
      io.closeInput();
    }
  }

  test(
      'checkboxes save globally, load live, retain selection and reset inheritance',
      () async {
    final output = await drive([
      CharInput('Plugins'),
      enter,
      CharInput('tina/goals'),
      space,
      () {
        expect(app.commands['goal'], isNotNull);
        expect(config.readAsStringSync(), contains("'tina/goals' = true"));
      },
      space,
      () => expect(app.commands['goal'], isNull),
      enter,
      () => expect(app.commands['goal'], isNotNull),
      reset,
      () {
        expect(app.commands['goal'], isNull);
        expect(app.pluginSettings.state('tina/goals').source, 'global');
      },
      escape,
      escape,
    ]);
    expect(output, contains('[x] tina/goals'));
    expect(output, contains('[ ] tina/goals'));
    expect(app.commands['plugins'], isNull);
    expect(app.commands.all.any((command) => command.name == 'plugins'), false);
  });

  test(
      'workspace and session checkboxes preserve precedence without copying global list',
      () async {
    app.pluginSettings
        .apply('tina/goals', true, PluginScope.global, app.pluginManager);
    await drive([
      CharInput('Plugins'), enter, enter, down, enter, // workspace
      CharInput('tina/goals'), space,
      () {
        expect(app.commands['goal'], isNull);
        expect(app.pluginSettings.state('tina/goals').source, 'workspace');
      },
      escape, escape,
    ]);
    final workspace = File('${root.path}/.tina/config');
    final persisted = workspace.readAsStringSync();
    expect(persisted, isNot(contains('enabled =')));
    await drive([
      CharInput('Plugins'), enter, enter, down, down, enter, // session
      CharInput('tina/goals'), space,
      () {
        expect(app.commands['goal'], isNotNull);
        expect(app.pluginSettings.state('tina/goals').source, 'session');
      },
      reset,
      () => expect(app.commands['goal'], isNull),
      escape, escape,
    ]);
    expect(workspace.readAsStringSync(), persisted);
    expect(
        app.pluginSettings
            .scopedState('tina/goals', PluginScope.global)
            .enabled,
        true);
  });

  test(
      'plugin saves preserve unsaved general settings and required plugins stay locked',
      () async {
    final output = await drive([
      CharInput('Default model'),
      enter,
      CharInput('Enter model'),
      enter,
      EditingKey(EditingAction.killToStart),
      CharInput('next-model'),
      enter,
      CharInput('Plugins'),
      enter,
      CharInput('tina/goals'),
      space,
      escape,
      CharInput('Plugins'),
      enter,
      CharInput('tina/tools'),
      space,
      escape,
      CharInput('Save'),
      enter,
    ]);
    expect(loadTinaConfig(path: config.path).config.model, 'next-model');
    expect(app.commands['goal'], isNotNull);
    expect(app.pluginSettings.state('tina/tools').source, 'required');
    expect(output, contains('required'));
    expect(config.readAsStringSync(), isNot(contains("'tina/tools' =")));
  });

  test(
      'restart-only checkboxes report pending restart without constructing a store',
      () async {
    final output = await drive([
      CharInput('Plugins'),
      enter,
      CharInput('tina/persistence'),
      space,
      escape,
      escape,
    ]);
    expect(app.host.plugins.any((p) => p.id == 'tina/persistence'), false);
    expect(app.pluginSettings.state('tina/persistence').enabled, true);
    // Full status is available even when the small terminal clips a row.
    expect(app.pluginSettings.status('tina/persistence', app.pluginManager),
        contains('pending restart'));
    expect(output, contains('[x] tina/persistence'));
  });
}
