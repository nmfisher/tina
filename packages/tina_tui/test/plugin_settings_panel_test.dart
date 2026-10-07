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
    // Former global-editor scenarios now select Global in the shared stack.
    var scopeTabs = scoped ? 0 : 2;
    late SettingsPanel panel;
    panel = SettingsPanel(screen, editor, readEvent: () async {
      if (scopeTabs > 0) {
        scopeTabs--;
        return ControlKey(ControlCode.tab);
      }
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
          pluginDescriptions: pluginDescriptions(app.pluginSettings.registry),
          pluginSettings: app.pluginSettings,
          pluginManager: app.pluginManager,
          scopedSettings: app.settings,
          settingsBackend: app.settingsBackend);
      expect(index, steps.length);
      return io.written.toString();
    } finally {
      editor.close();
      screen.dispose();
      io.closeInput();
    }
  }

  for (final scoped in [true]) {
    test(
        'workspace context can be promoted to All while its viewer requires it ($scoped)',
        () async {
      app.pluginSettings.apply(
          'tina/context', true, PluginScope.workspace, app.pluginManager);
      app.pluginSettings.apply(
          'tina/context-tui', true, PluginScope.session, app.pluginManager);
      app.settings.reload();
      // Use the production settings path for its session override too.
      if (scoped)
        app.settings.set(app.settings.catalog['tina/context-tui/enabled'], true,
            PluginScope.session);
      await drive([
        CharInput('Plugins'),
        enter,
        CharInput('tina/context'),
        scoped ? ArrowKey(ArrowDirection.left) : ArrowKey(ArrowDirection.right),
        space,
        if (!scoped) escape, // live viewer awaits the context plugin's restart
        escape,
        escape,
      ], resizeEachKey: false, scoped: scoped);
      expect(
          app.pluginSettings.overrideValue('tina/context', PluginScope.global),
          true);
      await drive([
        CharInput('Plugins'),
        enter,
        CharInput('tina/context-tui'),
        scoped ? ArrowKey(ArrowDirection.left) : ArrowKey(ArrowDirection.right),
        space,
        if (!scoped) escape,
        escape,
        escape,
      ], resizeEachKey: false, scoped: scoped);
      for (final id in ['tina/context', 'tina/context-tui']) {
        for (final scope in PluginScope.values) {
          expect(app.pluginSettings.overrideValue(id, scope), true,
              reason: '$id ${scope.name}');
        }
      }
      app.close();
      app = TuiAssembly.start(
          options: AssemblyOptions(
              configPath: config.path, workingDirectory: root.path),
          providerFactory: (_) => ScriptedProvider([]),
          registerPlugins: (registry) => registry.register(
              'acme/notes',
              (_) => throw StateError(
                  'Viewing metadata must not load this plugin'),
              description: 'Release notes'));
      for (final id in ['tina/context', 'tina/context-tui']) {
        expect(app.host.plugins.any((p) => p.id == id), true, reason: id);
        expect(app.pluginSettings.scopedState(id, PluginScope.global).enabled,
            true);
        expect(
            app.pluginSettings.scopedState(id, PluginScope.workspace).enabled,
            true);
        expect(app.pluginSettings.scopedState(id, PluginScope.session).enabled,
            true);
      }
      expect(app.commands['context'], isNotNull);
      final other = Directory('${root.path}/other-workspace')..createSync();
      final independent = TuiAssembly.start(
          options: AssemblyOptions(
              configPath: config.path, workingDirectory: other.path),
          providerFactory: (_) => ScriptedProvider([]),
          registerPlugins: (registry) => registry.register(
              'acme/notes', (_) => throw StateError('Disabled'),
              description: 'Release notes'));
      try {
        expect(independent.commands['context'], isNotNull);
        expect(
            independent.host.plugins.any((p) => p.id == 'tina/context'), true);
      } finally {
        independent.close();
      }
    });

    test(
        'All enables mixed overrides even when every scope inherits on ($scoped)',
        () async {
      final goals = app.settings.catalog['tina/goals/enabled'];
      if (scoped) {
        app.settings.set(goals, true, PluginScope.global);
      } else {
        app.pluginSettings
            .apply('tina/goals', true, PluginScope.global, app.pluginManager);
      }
      await drive([
        CharInput('Plugins'),
        enter,
        CharInput('tina/goals'),
        scoped ? ArrowKey(ArrowDirection.left) : ArrowKey(ArrowDirection.right),
        space,
        escape,
        escape,
      ], resizeEachKey: false, scoped: scoped);
      for (final scope in PluginScope.values) {
        expect(
            scoped
                ? app.settings.override(goals, scope)
                : app.pluginSettings.overrideValue('tina/goals', scope),
            true);
      }
    });

    test('narrow plugin grid retains all four columns ($scoped)', () async {
      final output = await drive([
        CharInput('Plugins'),
        enter,
        CharInput('tina/goals'),
        if (scoped)
          ArrowKey(ArrowDirection.left)
        else
          ArrowKey(ArrowDirection.right),
        space,
        escape,
        escape,
      ], resizeEachKey: false, scoped: scoped, onReady: (screen, _) {
        screen.resize(ScreenLayout.fromSize(40, 8, split: false));
      });
      expect(output, matches(RegExp(r'Sess\s+Work\s+Glob\s+All')));
      expect(output, contains('>[x]'));
      expect(app.pluginSettings.state('tina/goals').enabled, true);
    });

    test('four plugin columns edit individual layers and All ($scoped)',
        () async {
      bool? override(PluginScope scope) => scoped
          ? app.settings.override(
              app.settings.catalog['tina/goals/enabled'], scope) as bool?
          : app.pluginSettings.overrideValue('tina/goals', scope);
      final right = ArrowKey(ArrowDirection.right);
      final output = await drive([
        CharInput('Plugins'),
        enter,
        if (!scoped) ...[
          ArrowKey(ArrowDirection.left),
          ArrowKey(ArrowDirection.left)
        ],
        CharInput('tina/goals'),
        space,
        () {
          expect(override(PluginScope.session), true);
          expect(override(PluginScope.workspace), null);
          expect(override(PluginScope.global), false);
        },
        right,
        space,
        () {
          expect(override(PluginScope.workspace), true);
          expect(override(PluginScope.global), false);
        },
        right,
        space,
        () => expect(PluginScope.values.map(override), [true, true, true]),
        right,
        space,
        () {
          expect(PluginScope.values.map(override), [false, false, false]);
          expect(app.commands['goal'], isNull);
        },
        space,
        () {
          expect(PluginScope.values.map(override), [true, true, true]);
          expect(app.commands['goal'], isNotNull);
        },
        reset,
        () {
          expect(override(PluginScope.session), null);
          expect(override(PluginScope.workspace), null);
          expect(config.readAsStringSync(), isNot(contains("'tina/goals' =")));
          expect(File('${root.path}/.tina/config').readAsStringSync(),
              isNot(contains('enabled =')));
        },
        escape,
        escape,
      ], resizeEachKey: false, scoped: scoped);
      expect(output, matches(RegExp(r'Session\s+Workspace\s+Global\s+All')));
      expect(output, contains('[~]'));
      expect(output, contains('[-]'));
    });

    for (final narrow in [false, true]) {
      test(
          'selected plugin description is visible without help ($scoped, $narrow)',
          () async {
        final output = await drive([
          CharInput('Plugins'),
          enter,
          CharInput('acme/notes'),
          escape,
          escape,
        ], resizeEachKey: narrow, scoped: scoped);
        expect(output, contains('Summarizes release notes'));
        expect(output, isNot(contains('About acme/notes')));
        expect(app.host.plugins.any((p) => p.id == 'acme/notes'), false);
        if (!narrow) expect(output, contains('release.'));
      });
    }

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

  test('categories, pickers, inline fields and help share one frame', () async {
    late _TrackingBackend backend;
    late Screen screen;
    void stable() {
      final expected =
          dialogBounds(screen.layout, preferredWidth: 80, preferredHeight: 22);
      expect(backend.surfaces.last.bounds.toString(), expected.toString());
    }

    final output = await drive([
      stable,
      down, enter, stable, // Models category
      enter, stable, escape, stable, // model picker
      down, enter, stable, // provider tree
      ArrowKey(ArrowDirection.right), down, stable, // inline credential
      escape, stable,
      down, enter, stable, enter, stable, escape,
      stable, // provider + generation editor
      escape, stable, // root retains Models selection
      down, enter, stable, enter, stable, // Appearance / Theme choices
      down, escape, stable, escape, stable,
      down, enter, stable, escape, stable, // Permissions
      down, enter, stable, enter, stable, // Plugins / Enabled plugins
      CharInput('acme/notes'), CharInput('?'), stable,
      () => screen.resize(ScreenLayout.fromSize(40, 8, split: false)),
      down, stable,
      () => screen.resize(ScreenLayout.fromSize(100, 24, split: false)),
      down, stable,
      escape, stable, escape, stable, escape, stable, escape,
    ], resizeEachKey: false, onReady: (s, b) {
      screen = s;
      backend = b;
    });
    for (final category in [
      'General',
      'Models',
      'Appearance',
      'Permissions',
      'Plugins'
    ]) {
      expect(output, contains(category));
    }
    expect(output, contains('Settings › Models'));
    expect(output, contains('Choose default model'));
    expect(output, contains('Providers & models'));
    expect(output, contains('Generation · anthropic'));
    expect(output, contains('About acme/notes'));
  });

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
    expect(output, contains('next release.'));
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
        expect(
            app.settings.override(
                app.settings.catalog['tina/goals/enabled'], PluginScope.global),
            isNull);
      },
      escape,
      escape,
    ]);
    expect(output, matches(RegExp(r'tina/goals[^\n]*\[x\]')));
    expect(output, matches(RegExp(r'tina/goals[^\n]*\[ \]')));
    expect(app.commands['plugins'], isNull);
    expect(app.commands.all.any((command) => command.name == 'plugins'), false);
  });

  test(
      'workspace and session checkboxes preserve precedence without copying global list',
      () async {
    app.pluginSettings
        .apply('tina/goals', true, PluginScope.global, app.pluginManager);
    app.settings.reload();
    await drive([
      CharInput('Plugins'), enter, ArrowKey(ArrowDirection.left), // workspace
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
      CharInput('Plugins'), enter, ArrowKey(ArrowDirection.left),
      ArrowKey(ArrowDirection.left), // session
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
      escape,
    ]);
    expect(loadTinaConfig(path: config.path).config.model, 'next-model');
    expect(app.commands['goal'], isNotNull);
    expect(app.pluginSettings.state('tina/tools').source, 'required');
    expect(output, contains('required'));
    expect(
        app.settings.override(
            app.settings.catalog['tina/tools/enabled'], PluginScope.global),
        isNot(false));
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
    expect(output, matches(RegExp(r'tina/persiste[^\n]*\[x\]')));
  });
}
