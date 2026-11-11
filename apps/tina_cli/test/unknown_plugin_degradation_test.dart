// Graceful degradation for unknown enabled plugins: a packaged binary's
// registry is a subset of what a native checkout may know, so a config
// enabling an unknown plugin records, skips, and boots - it never
// refuses a working session. The interactive toggles still fail loudly.
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina/session.dart';

void main() {
  late Directory workspace;
  late File config;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('tina-unknown-plugin-');
    config = File('${workspace.path}/config');
  });
  tearDown(() => workspace.deleteSync(recursive: true));

  SessionAssembly assemble() => SessionAssembly.start(
        options: AssemblyOptions(
            configPath: config.path, workingDirectory: workspace.path),
        providerFactory: (_) => ScriptedProvider([scriptedReply('done')]),
      );

  const unknown = 'tina/not-a-real-plugin';

  test('an unknown enabled plugin is skipped, recorded, and booted', () {
    config.writeAsStringSync('''
version = 1

[default]
model = "anthropic/claude-sonnet-4-6"

[plugins]
enabled = [
  "tina/system-instruction",
  "$unknown",
]
''');
    final assembly = assemble();
    addTearDown(assembly.close);

    expect(assembly.pluginSettings.skippedPluginIds, [unknown]);
    expect(
      assembly.host.config.skippedPlugins,
      [unknown],
      reason: 'the snapshot records the skip alongside the features',
    );
    // Known plugins still load.
    expect(
      assembly.host.plugins.map((p) => p.id),
      contains('tina/system-instruction'),
    );
    // The skipped plugin never mounts.
    expect(
      assembly.host.plugins.map((p) => p.id),
      isNot(contains(unknown)),
    );

    // The snapshot carries the record; the notice channel carries the
    // explanation.
    final connection =
        assembly.host.connect(role: SessionRole.controller);
    addTearDown(connection.close);
    final attachment = connection.attach();
    // The attachment's initial snapshot carries the record, and the
    // notice channel carries the explanation.
    expect(attachment.initial.skippedPlugins, [unknown]);
    final noticeText = connection
        .notices(
          snapshot: attachment.initial,
          afterSeq: -1,
          limit: 64,
        )
        .entries
        .map((entry) => entry.text)
        .join('\n');
    expect(noticeText, contains('Skipped unknown plugins'));
    expect(noticeText, contains(unknown));
  });

  test('a config with ONLY unknown plugins still boots (empty-but-valid)',
      () {
    // selection_version 2 is the settings-managed shape: the enabled
    // list is respected verbatim (a v1 config would gain the legacy
    // profile plugins, which is the historical normalization, not this
    // edge). Only unknown plugins = an empty-but-valid selection.
    config.writeAsStringSync('''
version = 1

[default]
model = "anthropic/claude-sonnet-4-6"

[plugins]
selection_version = 2
enabled = [
  "$unknown",
]
''');
    final assembly = assemble();
    addTearDown(assembly.close);
    expect(assembly.pluginSettings.skippedPluginIds, [unknown]);
    expect(
      assembly.host.plugins.map((p) => p.id),
      unorderedEquals(['tina/providers', 'tina/approvals-tui']),
      reason: 'the structural provider mounts and the approval channel '
          'falls back to the first registered channel; the user-plugin '
          'selection is empty - the session is empty but valid',
    );
    expect(assembly.host.config.skippedPlugins, [unknown]);
  });

  test('interactive toggling of an unknown plugin still fails loudly', () {
    config.writeAsStringSync('''
version = 1

[default]
model = "anthropic/claude-sonnet-4-6"

[plugins]
enabled = ["tina/system-instruction"]
''');
    final assembly = assemble();
    addTearDown(assembly.close);
    expect(assembly.pluginSettings.skippedPluginIds, isEmpty);
    expect(
      () => assembly.pluginSettings.change(
          unknown, true, PluginScope.workspace),
      throwsArgumentError,
      reason: 'an explicit toggle must surface the typo, not silently skip',
    );
  });
}
