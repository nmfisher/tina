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
      (app.terminal as TuiTerminal).lines.map((l) => l.text).join('\n');

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
    await app.handleCommand('/plugins enable tina/goals --global');
    expect(app.commands['goal'], isNotNull);
    expect(app.pluginSettings.state('tina/goals').source, 'global');
    await app.handleCommand('/plugins disable tina/goals --workspace');
    expect(app.commands['goal'], isNull);
    expect(local.readAsStringSync(), contains('overrides'));
    expect(local.readAsStringSync(), isNot(contains('enabled =')));
    final persisted = local.readAsStringSync();
    await app.handleCommand('/plugins enable tina/goals'); // session is default
    expect(app.commands['goal'], isNotNull);
    expect(app.pluginSettings.state('tina/goals').source, 'session');
    expect(local.readAsStringSync(), persisted);
    await app.handleCommand('/plugins reset tina/goals --session');
    expect(app.commands['goal'], isNull);
    await app.handleCommand('/plugins reset tina/goals --workspace');
    expect(app.commands['goal'], isNotNull);
    await app.handleCommand('/plugins reset tina/goals --global');
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
    await app.handleCommand('/plugins disable tina/plans');
    expect(app.commands['plan'], isNull);
    expect(app.host.plugins.whereType<PlansPlugin>(), isEmpty);
    await app.host.send('without plans');
    final provider = app
        .host.session.loop.provider; // stream wrapper remains the same session
    await app.handleCommand('/plugins enable tina/plans');
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
    await app.handleCommand('/plugins enable tina/persistence --workspace');
    expect(app.host.plugins.any((p) => p.id == 'tina/persistence'), false);
    expect(File('${workspace.path}/.tina/sessions.db').existsSync(), false);
    expect(output(app), contains('pending restart'));
    await app.handleCommand('/plugins enable tina/goals');
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
    for (final line in [
      '/plugins disable unknown/plugin --global',
      '/plugins disable tina/tools --global',
      '/plugins enable tina/approvals-stream --global',
      '/plugins enable tina/goals --oops',
      '/plugins enable tina/goals --session --global',
    ]) {
      await app.handleCommand(line);
    }
    expect(global.readAsStringSync(), original);
    expect(app.commands['goal'], isNull);
    expect(local.existsSync(), false);
    expect(output(app), contains('unknown plugin'));
    expect(output(app), contains('required'));
    expect(output(app), contains('multiple providers'));
  });

  test('disabling persistence keeps the running store until restart', () async {
    global.writeAsStringSync(
        '[default]\nmodel="scripted"\n[plugins]\nenabled=["tina/persistence"]\n');
    final app = assemble();
    await app.handleCommand('/plugins disable tina/persistence --workspace');
    expect(app.host.plugins.any((p) => p.id == 'tina/persistence'), true);
    expect(output(app), contains('pending restart'));
    await app.host.send('still persisted');
    final restarted = assemble();
    expect(
        restarted.host.plugins.any((p) => p.id == 'tina/persistence'), false);
  });

  test('list distinguishes enabled, loaded, scope and restart state', () async {
    final app = assemble();
    await app.handleCommand('/plugins enable tina/subagents --workspace');
    await app.handleCommand('/plugins');
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
