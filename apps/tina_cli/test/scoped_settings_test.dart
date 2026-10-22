import 'package:tina_settings/tina_settings.dart';
import 'package:tina/src/config_settings_management.dart';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_tui/tina_tui.dart';
import 'package:tina/session.dart';
import 'package:tina_providers/tina_providers.dart';
import 'package:tina_mode/tina_mode.dart';
import 'package:tina_step_limit/tina_step_limit.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'app_test.dart' show FakeIo, fakeScreen;

final class Judge extends LlmProvider implements StructuredOutputProvider {
  Judge(super.model);
  final systems = <String>[];
  @override
  Stream<StreamEvent> send(
          {required String system,
          required List<Message> messages,
          required List<ToolSchema> tools}) =>
      Stream.value(const MessageComplete(
          content: [TextBlock('answer')], stopReason: 'end_turn'));
  @override
  Stream<StreamEvent> sendStructured(
      {required String system,
      required List<Message> messages,
      required JsonOutputSchema output}) {
    systems.add(system);
    return Stream.value(const MessageComplete(
        content: [TextBlock('{"decision":"ALLOW","reason":""}')],
        stopReason: 'end_turn'));
  }

  @override
  void close() {}
}

void main() {
  late Directory directory;
  late File global;
  late SessionAssembly app;
  final judges = <Judge>[];
  setUp(() {
    judges.clear();
    directory = Directory(Directory.systemTemp
        .createTempSync('tina-scoped-')
        .resolveSymbolicLinksSync());
    global = File('${directory.path}/config')..writeAsStringSync('''
[default]
model = "fixture"
[plugins]
enabled = ["tina/persistence", "tina/chat-tui", "tina/session-controls"]
[limits]
requests_per_minute = 0
[legacy_extension]
unknown = "preserve me"
''');
    final workspace = Directory('${directory.path}/workspace')..createSync();
    app = SessionAssembly.start(
        providerFactory: (model) {
          final judge = Judge(model);
          judges.add(judge);
          return judge;
        },
        options: AssemblyOptions(
            configPath: global.path, workingDirectory: workspace.path));
  });
  tearDown(() {
    app.close();
    directory.deleteSync(recursive: true);
  });
  SettingDefinition<Object> field(String id) => app.settings.catalog[id];
  final enter = ControlKey(ControlCode.enter), escape = EscapeKey();

  test(
    'trusted folders persist outside repository config and merge across scopes',
    () {
      final shared = Directory('${directory.path}/shared')..createSync();
      final local = Directory('${directory.path}/local')..createSync();
      final setting = field('tina/tools/read_only_directories');
      app.settings.set(setting, [shared.path], SettingScope.global);
      app.settings.set(setting, [local.path], SettingScope.workspace);
      expect(
        app.tools.readDirectories.paths,
        containsAll([shared.path, local.path]),
      );
      final workspaceConfig = File(app.settingsBackend.workspacePath);
      if (workspaceConfig.existsSync())
        expect(workspaceConfig.readAsStringSync(), isNot(contains(local.path)));
      expect(global.readAsStringSync(), isNot(contains(shared.path)));
      app.settings.reload();
      expect(app.settings.read(setting, scope: SettingScope.workspace).value, [
        local.path,
      ]);
      final grant = app.settingsBackend.permissionStore.entries.singleWhere(
        (entry) => entry['scope'] == 'global',
      );
      app.settingsBackend.permissionStore.revoke(grant['id'] as String);
      app.settings.reload();
      expect(app.tools.readDirectories.paths, [local.path]);
    },
  );

  test('repository settings cannot add trusted folders', () {
    final config = File(app.settingsBackend.workspacePath)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('''
[plugin_config."tina/tools"]
read_only_directories = ["/untrusted/folder"]
write_directories = ["/untrusted/writable"]
''');
    app.settings.reload();
    expect(
      app.tools.readDirectories.paths,
      isNot(contains('/untrusted/folder')),
    );
    expect(
      app.tools.writeDirectories.paths,
      isNot(contains('/untrusted/writable')),
    );
    expect(config.readAsStringSync(), contains('/untrusted/folder'));
  });

  test('revoking one trusted folder preserves other folders in the same scope',
      () {
    final first = Directory('${directory.path}/first')..createSync();
    final second = Directory('${directory.path}/second')..createSync();
    app.settings.set(field('tina/tools/read_only_directories'),
        [first.path, second.path], SettingScope.workspace);
    final management = ConfigSettingsManagement(
        scopedSettings: app.settings, backend: app.settingsBackend);
    final permission = management.commandApprovals.singleWhere(
        (entry) => entry['directory'] == first.resolveSymbolicLinksSync());
    management.revokeCommandApproval(permission['id'] as String);
    expect(
        app.tools.readDirectories.paths, [second.resolveSymbolicLinksSync()]);
    expect(
        management.commandApprovals.any(
            (entry) => entry['directory'] == first.resolveSymbolicLinksSync()),
        isFalse);
  });

  test('a stale permission edit cannot revive a revoked folder', () {
    final first = Directory('${directory.path}/first')..createSync();
    final second = Directory('${directory.path}/second')..createSync();
    final definition = field('tina/tools/read_only_directories');
    app.settings.set(definition, [first.path], SettingScope.workspace);
    final backend = app.settingsBackend;
    final previous = backend.read(SettingScope.workspace);
    final permission = backend.permissionStore.entries.single;
    backend.permissionStore.revoke(permission['id'] as String,
        directory: first.path);
    expect(() => backend.write(SettingScope.workspace,
        {...previous, definition.id: [first.path, second.path]}), throwsStateError);
    app.settings.reload();
    expect(app.tools.readDirectories.paths, isEmpty);
  });

  test('trusted folders pin aliases and reject retargeted canonical roots', () async {
    final trusted = Directory('${directory.path}/trusted')..createSync();
    final other = Directory('${directory.path}/other')..createSync();
    final alias = Link('${directory.path}/alias')..createSync(trusted.path);
    app.settings.set(field('tina/tools/read_only_directories'),
        [alias.path], SettingScope.workspace);
    expect(app.tools.readDirectories.paths, [trusted.path]);
    alias.updateSync(other.path);
    app.settings.reload();
    expect(app.tools.readDirectories.paths, [trusted.path]);
    trusted.renameSync('${directory.path}/moved');
    Link(trusted.path).createSync(other.path);
    app.settings.reload();
    expect(app.tools.readDirectories.paths, isEmpty);
    expect(app.tools.readDirectories.allows('${other.path}/source'), isFalse);
  }, skip: Platform.isWindows);

  test(
      'masked saves refresh plugin scope metadata without changing the active plugin',
      () {
    final goals = field('tina/goals/enabled');
    app.settings.set(goals, true, SettingScope.session);
    expect(app.commands['goal'], isNotNull);
    app.settings.set(goals, true, SettingScope.global);
    expect(
        app.pluginSettings
            .scopedState('tina/goals', PluginScope.global)
            .enabled,
        true);
    expect(app.pluginSettings.overrideValue('tina/goals', PluginScope.global),
        true);
    app.settings.set(goals, false, SettingScope.global);
    expect(
        app.pluginSettings
            .scopedState('tina/goals', PluginScope.global)
            .enabled,
        false);
    expect(
        app.pluginSettings
            .scopedState('tina/goals', PluginScope.session)
            .enabled,
        true);
    expect(app.commands['goal'], isNotNull);
    app.settings.removeOverride(goals, SettingScope.session);
    expect(app.commands['goal'], isNull);
  });

  test('All plugin scopes validate hidden consumers before writing any layer',
      () {
    app.settings.set(field('tina/context/enabled'), true, SettingScope.global);
    app.settings
        .set(field('tina/context-tui/enabled'), true, SettingScope.global);
    app.settings
        .set(field('tina/context-tui/enabled'), false, SettingScope.workspace);
    final beforeGlobal = global.readAsStringSync();
    final local = File(app.settingsBackend.workspacePath);
    final beforeWorkspace = local.readAsStringSync();
    final beforeSession = Map.of(app.settings.layer(SettingScope.session));
    expect(
        () => app.settingsBackend.setPluginInAllScopes(
            app.settings, field('tina/context/enabled'), false),
        throwsArgumentError);
    expect(global.readAsStringSync(), beforeGlobal);
    expect(local.readAsStringSync(), beforeWorkspace);
    expect(app.settings.layer(SettingScope.session), beforeSession);
  });

  test('All plugin scopes preserve unrelated settings and reject aliased files',
      () {
    final goals = field('tina/goals/enabled');
    app.settingsBackend.setPluginInAllScopes(app.settings, goals, true);
    expect(
        SettingScope.values.map((scope) => app.settings.override(goals, scope)),
        [true, true, true]);
    expect(global.readAsStringSync(), contains('preserve me'));
    expect(app.settings.read(field('tina/providers/requests_per_minute')).value,
        0);
    // An explicit config path can point at the workspace config itself.
    final same = SessionAssembly.start(
        providerFactory: (model) => Judge(model),
        options: AssemblyOptions(
            configPath: '${directory.path}/.tina/config',
            workingDirectory: directory.path));
    addTearDown(same.close);
    final original = global.readAsStringSync();
    expect(
        () => same.settingsBackend.setPluginInAllScopes(
            same.settings, same.settings.catalog['tina/goals/enabled'], true),
        throwsStateError);
    expect(global.readAsStringSync(), original);
    expect(
        same.settings.hasOverride(
            same.settings.catalog['tina/goals/enabled'], SettingScope.session),
        false);
  });

  test('terminal alerts persist globally and update existing sibling sessions',
      () {
    final alerts = field('tina/chat-tui/terminal_alerts');
    final sibling = app.newSession(null);
    addTearDown(sibling.close);
    expect(alerts.scopes, {SettingScope.global});
    expect(app.settings.read(alerts).value, true);
    app.settings.set(alerts, false, SettingScope.global);
    expect(app.settings.read(alerts).value, false);
    expect(sibling.settings.read(alerts).value, false);
    expect(global.readAsStringSync(), contains('[terminal]'));
    expect(global.readAsStringSync(), contains('alerts = false'));
    app.settings.set(alerts, true, SettingScope.global);
    expect(sibling.settings.read(alerts).value, true);
  });

  test('scope edits update live policy and respect sibling overrides', () {
    final sibling = app.newSession(null);
    addTearDown(sibling.close);
    final rpm = field('tina/providers/requests_per_minute');
    app.settings.set(rpm, 60, SettingScope.global);
    expect(
        app.host.plugins
            .whereType<ProviderPolicyPlugin>()
            .single
            .limits
            .requestsPerMinute,
        60);
    expect(sibling.settings.read(rpm).value, 60);
    app.settings.set(rpm, 10, SettingScope.workspace);
    expect(sibling.settings.read(rpm).value, 10);
    app.settings.set(rpm, 5, SettingScope.session);
    expect(app.settings.read(rpm).value, 5);
    expect(sibling.settings.read(rpm).value, 10);
    app.settings.set(rpm, 120, SettingScope.global);
    expect(app.settings.read(rpm).value, 5);
    expect(sibling.settings.read(rpm).value, 10);
    app.settings.removeOverride(rpm, SettingScope.session);
    expect(app.settings.read(rpm).value, 10);
    expect(global.readAsStringSync(), contains('preserve me'));
  });
  test('global changes and external file edits reach another workspace',
      () async {
    final other = Directory('${directory.path}/other')..createSync();
    final otherApp = SessionAssembly.start(
        providerFactory: (model) => Judge(model),
        options: AssemblyOptions(
            configPath: global.path, workingDirectory: other.path));
    addTearDown(otherApp.close);
    final rpm = field('tina/providers/requests_per_minute');
    app.settings.set(rpm, 30, SettingScope.workspace);
    global.writeAsStringSync(global
        .readAsStringSync()
        .replaceFirst('requests_per_minute = 0', 'requests_per_minute = 70'));
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(app.settings.read(rpm).value, 30);
    expect(otherApp.settings.read(rpm).value, 70);
  });
  test('session instruction and other overrides survive SQLite resume',
      () async {
    final instruction =
        "I'm ok with writing files to any directory outside the working directory";
    app.settings
        .set(classifierInstructionSetting, instruction, SettingScope.session);
    app.settings.set(stepLimitSetting, 12, SettingScope.session);
    expect(app.tools.modePolicy.classifier, isNotNull);
    final judgment = await app.tools.modePolicy.classifier!
        .classify({'operation': 'write file'});
    expect(judgment.allow, true);
    expect(
        judges.last.systems.single, startsWith('User permission preferences'));
    expect(judges.last.systems.single, contains(instruction));
    final id = app.host.session.id;
    final workspace = app.host.config.workingDirectory;
    app.close();
    app = SessionAssembly.start(
        providerFactory: (model) {
          final judge = Judge(model);
          judges.add(judge);
          return judge;
        },
        options: AssemblyOptions(
            configPath: global.path,
            workingDirectory: workspace,
            sessionId: id));
    expect(app.settings.read(classifierInstructionSetting).value, instruction);
    expect(app.settings.read(stepLimitSetting).value, 12);
    await app.tools.modePolicy.classifier!
        .classify({'operation': 'write file'});
    expect(judges.last.systems.single, contains(instruction));
    expect(global.readAsStringSync(), isNot(contains(instruction)));
  });
  test('unsupported scopes and invalid limits cannot modify files', () {
    final original = global.readAsStringSync();
    expect(
        () => app.settings
            .set(field('tina/chat-tui/theme'), 'dark', SettingScope.session),
        throwsArgumentError);
    expect(
        () => app.settings.set(field('tina/providers/requests_per_minute'), -1,
            SettingScope.global),
        throwsFormatException);
    expect(global.readAsStringSync(), original);
  });
  test('plugin selection is live, scoped, and retained when resuming', () {
    final sibling = app.newSession(null);
    addTearDown(sibling.close);
    final enabled = field('tina/grok-guard/enabled');
    app.settings.set(enabled, true, SettingScope.session);
    expect(app.host.plugins.map((p) => p.id), contains('tina/grok-guard'));
    expect(sibling.host.plugins.map((p) => p.id),
        isNot(contains('tina/grok-guard')));
    app.settings.set(enabled, false, SettingScope.workspace);
    expect(app.host.plugins.map((p) => p.id), contains('tina/grok-guard'));
    final id = app.host.session.id;
    final workspace = app.host.config.workingDirectory;
    app.close();
    app = SessionAssembly.start(
        providerFactory: (model) => Judge(model),
        options: AssemblyOptions(
            configPath: global.path,
            workingDirectory: workspace,
            sessionId: id));
    expect(app.host.plugins.map((p) => p.id), contains('tina/grok-guard'));
    app.settings.removeOverride(enabled, SettingScope.session);
    expect(
        app.host.plugins.map((p) => p.id), isNot(contains('tina/grok-guard')));
  });
  test('legacy selection survives normalization without disabling delivery',
      () {
    final enabled = app.host.plugins.map((p) => p.id).toSet();
    expect(app.settings.catalog.contains('tina/approvals-tui/enabled'), false);
    app.settings.set(
        field('tina/providers/requests_per_minute'), 60, SettingScope.global);
    expect(app.host.plugins.map((p) => p.id).toSet(), enabled);
    expect(app.settings.applicationErrors, isEmpty);
    expect(global.readAsStringSync(),
        isNot(contains('"tina/approvals-tui" = false')));
    expect(
        () => app.settings
            .set(field('tina/tools/enabled'), false, SettingScope.global),
        throwsArgumentError);
    expect(app.settings.applicationErrors, isEmpty);
  });
  test('thinking choices inherit as a unit and generation drafts save by scope',
      () {
    final thinking = field('tina/providers/anthropic/thinking');
    app.settings
        .set(thinking, {'thinking_budget': 2048}, SettingScope.workspace);
    app.settings
        .set(thinking, {'reasoning_effort': 'high'}, SettingScope.global);
    expect(app.settings.read(thinking).value, {'thinking_budget': 2048});
    final document = app.settingsBackend.effectiveDocument();
    expect((document['providers'] as Map)['anthropic'],
        containsPair('thinking_budget', 2048));
    expect((document['providers'] as Map)['anthropic'],
        isNot(contains('reasoning_effort')));
    final draft = app.settingsBackend.draft(app.settings, SettingScope.session);
    draft.saveGeneration(
        'anthropic', {'max_output': 16000, 'thinking_budget': 4096},
        descriptors: app.descriptors);
    expect(app.settings.read(thinking).value, {'thinking_budget': 4096});
    expect(
        app.settings.read(field('tina/providers/anthropic/max_output')).value,
        16000);
    expect(global.readAsStringSync(), isNot(contains('16000')));
  });
  test('stale file snapshots cannot overwrite external settings', () {
    final backend = app.settingsBackend;
    final values = backend.read(SettingScope.global);
    global.writeAsStringSync(global
        .readAsStringSync()
        .replaceFirst('requests_per_minute = 0', 'requests_per_minute = 70'));
    expect(
        () => backend.write(SettingScope.global,
            {...values, 'tina/providers/requests_per_minute': 60}),
        throwsStateError);
    expect(global.readAsStringSync(), contains('requests_per_minute = 70'));
  });
  test(
      'plugin checkbox can restore inheritance without leaving the filtered menu',
      () async {
    app.settings.set(field('tina/goals/enabled'), true, SettingScope.global);
    final io = FakeIo();
    final screen = fakeScreen(io);
    final input = LineEditor(screen: screen);
    final keys = <InputEvent>[
      CharInput('Plugins'),
      enter,
      CharInput('tina/goals'),
      CharInput(' '),
      ControlKey(ControlCode.ctrlR),
      escape,
      escape
    ];
    try {
      await SettingsPanel(screen, input,
              readEvent: () async => keys.removeAt(0))
          .run(
              management: ConfigSettingsManagement(
                  scopedSettings: app.settings,
                  backend: app.settingsBackend,
                  pluginSettings: app.pluginSettings,
                  pluginManager: app.pluginManager));
      expect(app.settings.read(field('tina/goals/enabled')).value, true);
      expect(
          app.settings
              .hasOverride(field('tina/goals/enabled'), SettingScope.session),
          false);
      expect(io.written.toString(), matches(RegExp(r'tina/goals[^\n]*\[x\]')));
    } finally {
      input.close();
      screen.dispose();
      io.closeInput();
    }
  });
  test('scope UI saves a session value, shows inheritance and formats commas',
      () async {
    final io = FakeIo();
    final visible = fakeScreen(io);
    final editor = LineEditor(screen: visible);
    final keys = <InputEvent>[
      CharInput('Request and token limits'),
      enter,
      CharInput('Requests per minute'),
      enter,
      EditingKey(EditingAction.killToStart),
      CharInput('1200'),
      enter,
      escape,
      escape,
    ];
    final original = global.readAsStringSync();
    try {
      final panel = SettingsPanel(visible, editor,
          readEvent: () async => keys.removeAt(0));
      expect(
          await panel.run(
              management: ConfigSettingsManagement(
                  scopedSettings: app.settings,
                  backend: app.settingsBackend,
                  pluginSettings: app.pluginSettings,
                  pluginManager: app.pluginManager)),
          true);
      expect(keys, isEmpty);
      expect(
          app.settings.read(field('tina/providers/requests_per_minute')).value,
          1200);
      expect(global.readAsStringSync(), original);
      expect(io.written.toString(), contains('[session]'));
      expect(io.written.toString(), contains('1,200'));
      expect(io.written.toString(), contains('Inherited from global'));
    } finally {
      editor.close();
      visible.dispose();
      io.closeInput();
    }
  });

  test('root search edits individual fields and Escape discards the editor',
      () async {
    final io = FakeIo();
    final screen = fakeScreen(io);
    final input = LineEditor(screen: screen);
    final keys = <InputEvent>[
      CharInput('Requests per minute'),
      enter,
      EditingKey(EditingAction.killToStart),
      CharInput('120'),
      escape,
      CharInput('Requests per minute'),
      enter,
      EditingKey(EditingAction.killToStart),
      CharInput('60'),
      enter,
      escape,
    ];
    final original = global.readAsStringSync();
    var reads = 0;
    try {
      final panel = SettingsPanel(screen, input, readEvent: () async {
        if (reads++ == 5) {
          expect(
              app.settings
                  .read(field('tina/providers/requests_per_minute'))
                  .value,
              0,
              reason: 'Escape must discard the unfinished text editor');
        }
        return keys.removeAt(0);
      });
      expect(
          await panel.run(
              management: ConfigSettingsManagement(
                  scopedSettings: app.settings, backend: app.settingsBackend)),
          true);
      expect(keys, isEmpty);
      expect(
          app.settings.read(field('tina/providers/requests_per_minute')).value,
          60);
      expect(global.readAsStringSync(), original);
    } finally {
      input.close();
      screen.dispose();
      io.closeInput();
    }
  });

  test('an open field rejects another attachment changing its value', () async {
    final io = FakeIo();
    final screen = fakeScreen(io);
    final input = LineEditor(screen: screen);
    final keys = <InputEvent>[
      CharInput('Requests per minute'), enter,
      EditingKey(EditingAction.killToStart), CharInput('120'), enter,
      escape, // conflict message
      escape, // settings
    ];
    var reads = 0;
    final panel = SettingsPanel(screen, input, readEvent: () async {
      if (reads++ == 4) {
        app.settings.set(field('tina/providers/requests_per_minute'), 60,
            SettingScope.session);
      }
      return keys.removeAt(0);
    });
    try {
      expect(
          await panel.run(
              management: ConfigSettingsManagement(
                  scopedSettings: app.settings, backend: app.settingsBackend)),
          false);
      expect(
          app.settings.read(field('tina/providers/requests_per_minute')).value,
          60);
      expect(io.written.toString(), contains('Settings changed'));
      expect(keys, isEmpty);
    } finally {
      input.close();
      screen.dispose();
      io.closeInput();
    }
  });

  test('setting lists retain filtering and scope while resetting inheritance',
      () async {
    final io = FakeIo();
    final screen = fakeScreen(io);
    final input = LineEditor(screen: screen);
    final keys = <InputEvent>[
      enter, // General
      enter, // Request and token limits
      CharInput('Requests per minute'), ControlKey(ControlCode.tab), enter,
      EditingKey(EditingAction.killToStart), CharInput('45'), enter,
      ControlKey(ControlCode.ctrlR),
      escape, escape, escape,
    ];
    try {
      await SettingsPanel(screen, input,
              readEvent: () async => keys.removeAt(0))
          .run(
              management: ConfigSettingsManagement(
                  scopedSettings: app.settings, backend: app.settingsBackend));
      expect(keys, isEmpty);
      expect(
          app.settings.hasOverride(field('tina/providers/requests_per_minute'),
              SettingScope.workspace),
          false);
      expect(
          app.settings.read(field('tina/providers/requests_per_minute')).value,
          0);
      expect(io.written.toString(), contains('[workspace]'));
    } finally {
      input.close();
      screen.dispose();
      io.closeInput();
    }
  });
}
