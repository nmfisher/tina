import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_tools/tina_tools.dart';
import 'package:tina_tui/tina_tui.dart';

class AlternateModels extends AgentPlugin implements ModelAccess {
  @override
  String get id => 'acme/models';
  int calls = 0;
  @override
  LlmProvider mainProvider(String model) {
    calls++;
    return ScriptedProvider([scriptedReply('alternate')]);
  }

  @override
  LlmProvider childProvider(String model) => mainProvider(model);
}

void main() {
  late Directory root;
  late File config;
  setUp(() {
    root = Directory.systemTemp.createTempSync('policy-migration-');
    config = File('${root.path}/config');
  });
  tearDown(() => root.deleteSync(recursive: true));
  TuiAssembly start(
          {String? resume,
          void Function(PluginRegistry<TuiPluginContext>)? register}) =>
      TuiAssembly.start(
          options: AssemblyOptions(
              configPath: config.path,
              workingDirectory: root.path,
              sessionId: resume),
          providerFactory: (_) => ScriptedProvider([scriptedReply('done')]),
          registerPlugins: register);

  test(
      'explicit selection supports another publisher model provider without system instruction or tools',
      () async {
    config.writeAsStringSync(
        '[default]\nmodel="test"\n[plugins]\nselection_version=2\nenabled=["acme/models"]\n');
    final models = AlternateModels();
    final app = start(
        register: (r) => r.registerDefinition(PluginDefinition(
            'acme/models', (_) => models,
            description: 'Alternate model access', provides: [modelAccess])));
    addTearDown(app.close);
    expect(app.host.plugins.any((p) => p.id == 'tina/system-instruction'), false);
    expect(app.host.plugins.any((p) => p.id == 'tina/tools'), false);
    expect((await app.host.send('go')).detail, 'alternate');
    expect(models.calls, 1);
  });

  test('mode survives resume; removing the mode UI does not remove enforcement',
      () async {
    config.writeAsStringSync(
        '[default]\nmodel="test"\n[plugins]\nselection_version=2\nenabled=["tina/providers","tina/tools","tina/approvals","tina/mode","tina/persistence"]\n');
    final app = start();
    await app.handleCommand('/mode read-only');
    final id = app.host.session.id;
    final saved = app.host.session.loop.log
        .whereType<PluginStateEntry>()
        .where((e) => e.pluginId == 'tina/tools')
        .toList();
    expect(saved, hasLength(1));
    expect(saved.single.value, {'mode': 'read-only'});
    app.pluginSettings
        .apply('tina/mode', false, PluginScope.session, app.pluginManager);
    expect(app.commands['mode'], isNull);
    expect(app.tools.mode, PermissionMode.readOnly);
    expect(app.tools.sandbox.mode, PermissionMode.readOnly);
    expect(app.tools.processRunner.mode, PermissionMode.readOnly);
    app.close();
    final resumed = start(resume: id);
    addTearDown(resumed.close);
    expect(resumed.tools.mode, PermissionMode.readOnly);
    expect(
        resumed.host.session.loop.log
            .whereType<PluginStateEntry>()
            .where((e) => e.pluginId == 'tina/tools'),
        hasLength(1));
  });

  test('dependencies lock only while their consumers remain selected', () {
    config.writeAsStringSync(
        '[default]\nmodel="test"\n[plugins]\nselection_version=2\nenabled=["tina/providers","tina/plans","tina/approvals"]\n');
    final app = start();
    addTearDown(app.close);
    expect(app.pluginSettings.blockingReasons['tina/approvals'],
        contains('tina/plans requires tina/approval-requester'));
    app.pluginSettings
        .apply('tina/plans', false, PluginScope.session, app.pluginManager);
    expect(app.pluginSettings.requiredIds, isNot(contains('tina/approvals')));
    expect(app.pluginSettings.requiredIds, isNot(contains('tina/system-instruction')));
  });

  test('invalid global graph is rejected even when a session masks it', () {
    config.writeAsStringSync(
        '[default]\nmodel="test"\n[plugins]\nselection_version=2\nenabled=["tina/providers","tina/plans"]\n');
    expect(
        () => TuiAssembly.start(
            options: AssemblyOptions(
                configPath: config.path,
                workingDirectory: root.path,
                plugins: []),
            providerFactory: (_) => ScriptedProvider([])),
        throwsArgumentError);
  });
}
