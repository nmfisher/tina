import 'support/session_connection.dart';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_persistence/tina_persistence.dart';
import 'package:tina/session.dart';
import 'package:tina/src/console_catalog.dart';
import 'package:tina_cwd_tui/tina_cwd_tui.dart';

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

  SessionAssembly assemble() => SessionAssembly.start(
        options: AssemblyOptions(
            configPath: config.path, workingDirectory: workspace.path),
        providerFactory: (_) => ScriptedProvider([scriptedReply('done')]),
      );

  test('CWD plugin uses the session workspace and supports live toggling', () {
    final assembly = assemble();
    addTearDown(assembly.close);
    CwdView view() => createConsoleView(
        assembly.host.plugins
            .singleWhere((plugin) => plugin.id == 'tina/cwd-tui'),
        connection: testConnection(host: assembly.host)) as CwdView;
    expect(view().workingDirectory, workspace.absolute.path);
    expect(view(), isNot(same(view())));
    assembly.pluginSettings.apply(
        'tina/cwd-tui', false, PluginScope.session, assembly.pluginManager);
    expect(assembly.host.plugins.any((plugin) => plugin.id == 'tina/cwd-tui'),
        isFalse);
    assembly.pluginSettings.apply(
        'tina/cwd-tui', true, PluginScope.session, assembly.pluginManager);
    expect(view().workingDirectory, workspace.absolute.path);
  });

  test('defaults mount the selected first-party plugins and persist a turn',
      () async {
    final assembly = assemble();
    addTearDown(assembly.close);
    expect(
        assembly.host.config.plugins
            .whereType<PersistencePlugin>()
            .single
            .store
            .list(),
        isEmpty,
        reason: 'startup alone is not session activity');
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
        containsAll(['update_plan', 'launch_subagent', 'subagent']));
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

  test('malformed plugin selections fail without creating a store or provider',
      () {
    for (final setting in [
      'enabled=["plans"]',
      'enabled=["tina/plans", "tina/plans"]',
      'enabled=true',
      'enabled=[42]',
      'enabld=[]',
      'enabled=[',
    ]) {
      config
          .writeAsStringSync('[default]\nmodel="test"\n[plugins]\n$setting\n');
      var built = false;
      expect(
          () => SessionAssembly.start(
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

  // Unknown plugin IDS are not malformed selections: a packaged binary's
  // registry is a subset of what a native checkout may know, so boot
  // degrades gracefully - the id is skipped, recorded on the settings and
  // the snapshot, and the session still builds. Malformed SHAPES above
  // keep failing closed.
  test('unknown plugin ids skip and boot without a store', () {
    for (final setting in [
      'enabled=["acme/missing"]',
      'enabled=["tina/workflows"]',
    ]) {
      config
          .writeAsStringSync('[default]\nmodel="test"\n[plugins]\n$setting\n');
      var built = false;
      final assembly = SessionAssembly.start(
        options: AssemblyOptions(
            configPath: config.path, workingDirectory: workspace.path),
        providerFactory: (_) {
          built = true;
          return ScriptedProvider([]);
        },
      );
      addTearDown(assembly.close);
      expect(built, isTrue, reason: '$setting degrades gracefully');
      expect(assembly.pluginSettings.skippedPluginIds, isNotEmpty,
          reason: setting);
      expect(assembly.host.config.skippedPlugins,
          assembly.pluginSettings.skippedPluginIds);
      expect(
          File(defaultSessionStorePath(workspace.path)).existsSync(), isFalse,
          reason: 'persistence was never enabled');
    }
  });

  test('resume cannot silently bypass disabled persistence', () {
    config
        .writeAsStringSync('[default]\nmodel="test"\n[plugins]\nenabled=[]\n');
    expect(
        () => SessionAssembly.start(
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
