import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tui/tina_tui.dart';
import 'package:tina_tui/src/plugin_catalog.dart' show pluginDescriptions;
import 'app_test.dart' show FakeIo;

class _TrackingBackend extends AnsiBackend {
  _TrackingBackend(Stdio io) : super(io: io, ansi: AnsiCapable.yes);
  final surfaces = <BackendSurface>[];
  @override
  BackendSurface createSurface(Rect bounds) {
    final surface = super.createSurface(bounds);
    surfaces.add(surface);
    return surface;
  }
}

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
        providerFactory: (_) => ScriptedProvider([]),
        registerPlugins: (registry) => registry.register(
            'acme/notes',
            (_) =>
                throw StateError('Viewing metadata must not load this plugin'),
            description:
                'Summarizes release notes from recent commits and groups changes for the next release.'));
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

  Future<String> drive(List<Object> steps,
      {bool resizeEachKey = true,
      bool scoped = false,
      void Function(Screen, _TrackingBackend)? onReady}) async {
    final io = FakeIo();
    final backend = _TrackingBackend(io);
    final screen = Screen.withBackend(
        io: io,
        backend: backend,
        layout: ScreenLayout.fromSize(100, 24, split: false));
    onReady?.call(screen, backend);
    final editor = LineEditor(screen: screen);
    var index = 0;
    late SettingsPanel panel;
    panel = SettingsPanel(screen, editor, readEvent: () async {
      while (index < steps.length && steps[index] is void Function()) {
        (steps[index++] as void Function())();
      }
      if (index >= steps.length) fail('unexpected key read');
      if (resizeEachKey) {
        screen.resize(
            ScreenLayout.fromSize(index.isEven ? 40 : 100, 8, split: false));
      }
      panel.repaint();
      return steps[index++] as InputEvent;
    });
    try {
      await panel.run(
          path: config.path,
          pluginIds: app.pluginSettings.registry.ids,
          pluginDescriptions: pluginDescriptions(app.pluginSettings.registry),
          pluginSettings: app.pluginSettings,
          pluginManager: app.pluginManager,
          scopedSettings: scoped ? app.settings : null,
          settingsBackend: scoped ? app.settingsBackend : null);
      expect(index, steps.length);
      return io.written.toString();
    } finally {
      editor.close();
      screen.dispose();
      io.closeInput();
    }
  }

  for (final scoped in [false, true]) {
    test(
        'plugin menu keeps its bounds across toggles, filtering and scopes ($scoped)',
        () async {
      late _TrackingBackend backend;
      late Screen screen;
      late String original;
      late int creations;
      void stable() {
        expect(backend.surfaces.last.bounds.toString(), original);
        expect(backend.surfaces.length, creations,
            reason: 'content changes must retain the menu surface');
      }

      await drive([
        CharInput('Plugins'), enter,
        () {
          original = backend.surfaces.last.bounds.toString();
          creations = backend.surfaces.length;
        },
        down, stable, // selection changes description
        CharInput('tina/goals'), stable,
        space, stable,
        space, stable,
        reset, stable,
        if (scoped) ...[ControlKey(ControlCode.tab), stable],
        CharInput('no-such-plugin'), stable,
        for (var i = 0; i < 'no-such-plugin'.length; i++)
          ControlKey(ControlCode.backspace),
        stable,
        () => screen.resize(ScreenLayout.fromSize(40, 8, split: false)),
        down,
        () {
          final bounds = backend.surfaces.last.bounds;
          final area = dialogArea(screen.layout);
          expect(bounds.width, lessThanOrEqualTo(area.width));
          expect(bounds.height, lessThanOrEqualTo(area.height));
          expect(bounds.right, lessThanOrEqualTo(area.right));
          expect(bounds.bottom, lessThanOrEqualTo(area.bottom));
          expect(bounds.toString(), isNot(original));
          original = bounds.toString();
          creations = backend.surfaces.length;
        },
        space, stable, escape, escape,
      ], resizeEachKey: false, scoped: scoped, onReady: (s, b) {
        screen = s;
        backend = b;
      });
    });
  }

  test(
      'disabled plugin descriptions come from registration and open fully on narrow screens',
      () async {
    final output = await drive([
      CharInput('Plugins'),
      enter,
      CharInput('acme/notes'),
      CharInput('?'),
      down,
      down,
      escape,
      escape,
      escape,
    ]);
    expect(output, contains('Summarizes release notes'));
    expect(output, contains('About acme/notes'));
    expect(app.host.plugins.any((p) => p.id == 'acme/notes'), false);
    final metadata = pluginDescriptions(app.pluginSettings.registry);
    for (final id in {
      ...app.pluginSettings.registry.ids,
      ...app.pluginSettings.requiredIds
    }) {
      expect(metadata[id], isNotEmpty, reason: id);
    }
  });

  test('About wraps the full plugin description within the menu width',
      () async {
    final output = await drive([
      CharInput('Plugins'),
      enter,
      CharInput('acme/notes'),
      CharInput('?'),
      escape,
      escape,
      escape,
    ], resizeEachKey: false);
    expect(output, contains('About acme/notes'));
    expect(output, contains('Summarizes release notes'));
    expect(output, contains('the next release.'));
  });

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
    config.writeAsStringSync('${config.readAsStringSync()}\n'
        '[providers.anthropic]\nmodels = ["scripted", "next-model"]\n');
    final output = await drive([
      CharInput('Default model'),
      enter,
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
