import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_plans/tina_plans.dart';
import 'package:tina_tui/tina_tui.dart';

void main() {
  late Directory root, workspace;
  late File global, local;
  setUp(() {
    root = Directory.systemTemp.createTempSync('scoped-plugins-');
    workspace = Directory('${root.path}/workspace')..createSync();
    global = File('${root.path}/global')
      ..writeAsStringSync(
          '[default]\nmodel="scripted"\n[plugins]\nenabled=["tina/plans"]\n');
    local = File('${workspace.path}/.tina/config');
  });
  tearDown(() => root.deleteSync(recursive: true));
  TuiAssembly assemble() {
    final result = TuiAssembly.start(
        options: AssemblyOptions(
            configPath: global.path, workingDirectory: workspace.path),
        providerFactory: (_) =>
            ScriptedProvider(List.generate(8, (_) => scriptedReply('ok'))));
    addTearDown(result.close);
    return result;
  }

  String output(TuiAssembly app) =>
      app.pluginSettings.describe(app.pluginManager);

  test('workspace overrides inherit the global list without copying it', () {
    local.parent.createSync();
    local.writeAsStringSync(
        '[plugins.overrides]\n"tina/plans"=false\n"tina/goals"=true\n');
    final app = assemble();
    expect(app.commands['plan'], isNull);
    expect(app.commands['goal'], isNotNull);
    expect(app.pluginSettings.state('tina/goals').source, 'workspace');
    expect(app.pluginSettings.state('tina/file-resources').source, 'global');
    expect(File('${workspace.path}/.tina/sessions.db').existsSync(), false);
  });

  test(
      'global, workspace and session changes honor precedence; reset restores inheritance',
      () async {
    final app = assemble();
    app.pluginSettings
        .apply('tina/goals', true, PluginScope.global, app.pluginManager);
    expect(app.commands['goal'], isNotNull);
    expect(app.pluginSettings.state('tina/goals').source, 'global');
    app.pluginSettings
        .apply('tina/goals', false, PluginScope.workspace, app.pluginManager);
    expect(app.commands['goal'], isNull);
    expect(local.readAsStringSync(), contains('overrides'));
    expect(local.readAsStringSync(), isNot(contains('enabled =')));
    final persisted = local.readAsStringSync();
    app.pluginSettings.apply('tina/goals', true, PluginScope.session,
        app.pluginManager); // session is default
    expect(app.commands['goal'], isNotNull);
    expect(app.pluginSettings.state('tina/goals').source, 'session');
    expect(local.readAsStringSync(), persisted);
    app.pluginSettings
        .apply('tina/goals', null, PluginScope.session, app.pluginManager);
    expect(app.commands['goal'], isNull);
    app.pluginSettings
        .apply('tina/goals', null, PluginScope.workspace, app.pluginManager);
    expect(app.commands['goal'], isNotNull);
    app.pluginSettings
        .apply('tina/goals', null, PluginScope.global, app.pluginManager);
    expect(app.commands['goal'],
        isNull); // restored original explicit global baseline
    final restarted = assemble();
    expect(restarted.commands['goal'], isNull);
    expect(restarted.commands['plan'], isNotNull);
  });

  test(
      'unloading and reloading plans preserves transcript and rehydrates state',
      () async {
    final app = assemble();
    final plan = app.host.plugins.whereType<PlansPlugin>().single;
    await plan.execute({
      'items': [
        {'text': 'keep this plan', 'state': 'pending'}
      ]
    });
    final entries = app.host.session.loop.log.length;
    app.pluginSettings
        .apply('tina/plans', false, PluginScope.session, app.pluginManager);
    expect(app.commands['plan'], isNull);
    expect(app.host.plugins.whereType<PlansPlugin>(), isEmpty);
    await app.host.send('without plans');
    final provider = app
        .host.session.loop.provider; // stream wrapper remains the same session
    app.pluginSettings
        .apply('tina/plans', true, PluginScope.session, app.pluginManager);
    expect(app.pluginManager.lastError, isNull);
    final restored = app.host.plugins.whereType<PlansPlugin>().single;
    expect(identical(plan, restored), false);
    expect(restored.store.state.items.single.text, 'keep this plan');
    expect(app.host.session.loop.log.length, greaterThan(entries));
    expect(app.host.session.loop.provider, same(provider));
    await restored.execute({
      'items': [
        {'text': 'new plan', 'state': 'done'}
      ]
    }); // no leaked closed subscription
    expect(restored.store.state.items.single.text, 'new plan');
  });

  test(
      'persistence and subagents remain pending restart while live changes still work',
      () async {
    final app = assemble();
    app.pluginSettings.apply(
        'tina/persistence', true, PluginScope.workspace, app.pluginManager);
    expect(app.host.plugins.any((p) => p.id == 'tina/persistence'), false);
    expect(File('${workspace.path}/.tina/sessions.db').existsSync(), false);
    expect(output(app), contains('pending restart'));
    app.pluginSettings
        .apply('tina/goals', true, PluginScope.session, app.pluginManager);
    expect(app.commands['goal'], isNotNull);
    final restarted = assemble();
    expect(restarted.host.plugins.any((p) => p.id == 'tina/persistence'), true);
    expect(File('${workspace.path}/.tina/sessions.db').existsSync(), true);
  });

  test(
      'unknown, required and conflicting plugins do not change config or runtime',
      () async {
    final app = assemble();
    final original = global.readAsStringSync();
    for (final id in [
      'unknown/plugin',
      'tina/tools',
      'tina/approvals-stream'
    ]) {
      expect(
          () => app.pluginSettings
              .apply(id, true, PluginScope.global, app.pluginManager),
          throwsArgumentError);
    }
    expect(app.commands['plugins'], isNull);
    expect(global.readAsStringSync(), original);
    expect(app.commands['goal'], isNull);
    expect(local.existsSync(), false);
  });

  test('disabling persistence keeps the running store until restart', () async {
    global.writeAsStringSync(
        '[default]\nmodel="scripted"\n[plugins]\nenabled=["tina/persistence"]\n');
    final app = assemble();
    app.pluginSettings.apply(
        'tina/persistence', false, PluginScope.workspace, app.pluginManager);
    expect(app.host.plugins.any((p) => p.id == 'tina/persistence'), true);
    expect(output(app), contains('pending restart'));
    await app.host.send('still persisted');
    final restarted = assemble();
    expect(
        restarted.host.plugins.any((p) => p.id == 'tina/persistence'), false);
  });

  test('list distinguishes enabled, loaded, scope and restart state', () async {
    final app = assemble();
    app.pluginSettings.apply(
        'tina/subagents', true, PluginScope.workspace, app.pluginManager);
    expect(
        output(app),
        contains(
            'tina/subagents | enabled | no | workspace | pending restart'));
    expect(output(app), contains('tina/plans | enabled | yes | global | live'));
    expect(output(app), contains('tina/tools | enabled | yes | required'));
  });

  test('malformed workspace overrides fail before opening the provider', () {
    local.parent.createSync();
    for (final text in [
      '[plugins.overrides]\n"tina/goals"="yes"\n',
      '[plugins.overrides]\n"unknown/plugin"=false\n',
      '[plugins]\nenabled=[]\n',
      '[plugins.overrides]\n"tina/tools"=false\n',
    ]) {
      local.writeAsStringSync(text);
      var opened = false;
      expect(
          () => TuiAssembly.start(
              options: AssemblyOptions(
                  configPath: global.path, workingDirectory: workspace.path),
              providerFactory: (_) {
                opened = true;
                return ScriptedProvider([]);
              }),
          throwsA(anyOf(isA<FormatException>(), isA<ArgumentError>())));
      expect(opened, false);
    }
  });
}
