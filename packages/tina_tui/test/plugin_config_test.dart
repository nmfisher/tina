import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_persistence/tina_persistence.dart';
import 'package:tina_tui/tina_tui.dart';

void main() {
  test('legacy system-instruction selections retain their enabled state', () {
    expect(pluginBaseline(['tina/persona'], selectionVersion: 2),
        ['tina/system-instruction']);
    expect(
        parsePluginOverrides({
          'overrides': {'tina/persona': false}
        }),
        {'tina/system-instruction': false});
    expect(
        parsePluginOverrides({
          'overrides': {'tina/system-instruction': true, 'tina/persona': false}
        }),
        {'tina/system-instruction': true});
  });

  late Directory workspace;
  late File config;
  setUp(() {
    workspace = Directory.systemTemp.createTempSync('tina-plugin-config-');
    config = File('${workspace.path}/config');
  });
  tearDown(() => workspace.deleteSync(recursive: true));

  TuiAssembly assemble() => TuiAssembly.start(
        options: AssemblyOptions(
            configPath: config.path, workingDirectory: workspace.path),
        providerFactory: (_) => ScriptedProvider([scriptedReply('done')]),
      );

  test('defaults mount the selected first-party plugins and persist a turn',
      () async {
    final assembly = assemble();
    addTearDown(assembly.close);
    expect(assembly.host.config.plugins.map((p) => p.id),
        containsAll(defaultPluginIds));
    expect(
        assembly.commands.all.map((c) => c.name),
        containsAll([
          'plan',
          'goal',
          'mode',
          'model',
          'compact',
          'clear',
          'settings',
          'quit'
        ]));
    for (final legacy in ['session', 'sessions', 'resume', 'save']) {
      expect(assembly.commands[legacy], isNull,
          reason: 'session command ports are explicitly deferred');
    }
    expect(
        assembly.host.config.plugins.expand((p) => p.tools).map((t) => t.name),
        containsAll(['update_plan', 'spawn_subagent']));
    await assembly.host.send('hello');
    final persistence =
        assembly.host.config.plugins.whereType<PersistencePlugin>().single;
    expect(persistence.store.readEntries(assembly.host.session.id), isNotEmpty);
    expect(persistence.store.list(), hasLength(1));
    expect(File(defaultSessionStorePath(workspace.path)).existsSync(), isTrue);
    expect(assembly.host.config.plugins.any((p) => p.id == 'tina/workflows'),
        isFalse);
  });

  test('an explicit empty list disables feature plugins and all store I/O',
      () async {
    config
        .writeAsStringSync('[default]\nmodel="test"\n[plugins]\nenabled=[]\n');
    final assembly = assemble();
    addTearDown(assembly.close);
    expect(
        assembly.host.config.plugins.map((p) => p.id),
        unorderedEquals([
          'tina/system-instruction',
          'tina/providers',
          'tina/mode',
          'tina/approvals-tui',
          'tina/approvals',
          'tina/tools'
        ]));
    await assembly.host.send('hello');
    expect(assembly.commands['plan'], isNull);
    expect(assembly.commands['goal'], isNull);
    expect(File(defaultSessionStorePath(workspace.path)).existsSync(), isFalse);
  });

  test('multiline TOML and comments select exactly the named feature plugins',
      () {
    config.writeAsStringSync('''
[default]
model = "test"
[plugins]
enabled = [
  "tina/plans", # opt in to just plans
]
''');
    final assembly = assemble();
    addTearDown(assembly.close);
    expect(assembly.commands['plan'], isNotNull);
    expect(assembly.commands['goal'], isNull);
    expect(File(defaultSessionStorePath(workspace.path)).existsSync(), isFalse);
  });

  test('bad plugin selections fail without creating a store or provider', () {
    for (final setting in [
      'enabled=["plans"]',
      'enabled=["tina/plans", "tina/plans"]',
      'enabled=["acme/missing"]',
      'enabled=["tina/workflows"]',
      'enabled=true',
      'enabled=[42]',
      'enabld=[]',
      'enabled=[',
    ]) {
      config
          .writeAsStringSync('[default]\nmodel="test"\n[plugins]\n$setting\n');
      var built = false;
      expect(
          () => TuiAssembly.start(
                options: AssemblyOptions(
                    configPath: config.path, workingDirectory: workspace.path),
                providerFactory: (_) {
                  built = true;
                  return ScriptedProvider([]);
                },
              ),
          throwsA(anyOf(isA<FormatException>(), isA<ArgumentError>())));
      expect(built, isFalse);
      expect(
          File(defaultSessionStorePath(workspace.path)).existsSync(), isFalse);
    }
  });

  test('resume cannot silently bypass disabled persistence', () {
    config
        .writeAsStringSync('[default]\nmodel="test"\n[plugins]\nenabled=[]\n');
    expect(
        () => TuiAssembly.start(
              options: AssemblyOptions(
                  configPath: config.path,
                  workingDirectory: workspace.path,
                  sessionId: 'old'),
              providerFactory: (_) => ScriptedProvider([]),
            ),
        throwsArgumentError);
  });

  test('the global config path honors the supplied home', () {
    final global = File('${workspace.path}/.tina/config');
    global.parent.createSync();
    global
        .writeAsStringSync('[default]\nmodel="test"\n[plugins]\nenabled=[]\n');
    final result = loadTinaConfig(environment: {'HOME': workspace.path});
    expect(result.config.plugins, legacyProfilePlugins);
  });
}
