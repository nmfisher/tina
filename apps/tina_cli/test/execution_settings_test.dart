import 'dart:io';

import 'package:test/test.dart';
import 'package:tina/session.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_settings/tina_settings.dart';
import 'package:tina_tools/tina_tools.dart';

void main() {
  test(
    'execution context settings survive resume and remain conversation scoped',
    () async {
      final root = Directory(
        Directory.systemTemp
            .createTempSync('execution-settings-')
            .resolveSymbolicLinksSync(),
      );
      final workspace = Directory('${root.path}/project')..createSync();
      final sub = Directory('${workspace.path}/sub')..createSync();
      final config = File('${root.path}/config')
        ..writeAsStringSync('''
[default]
model = "fixture"
[plugins]
enabled = ["tina/persistence"]
''');
      SessionAssembly create({String? id}) => SessionAssembly.start(
        options: AssemblyOptions(
          configPath: config.path,
          workingDirectory: workspace.path,
          sessionId: id,
        ),
        providerFactory: (_) => ScriptedProvider([scriptedReply('done')]),
      );
      var assembly = create();
      try {
        final tools = assembly.tools as ToolsPlugin;
        expect(tools.osPlan.searchPath, contains('/opt/homebrew/bin'));
        expect(
          assembly.settings.catalog[commandWorkingDirectorySetting.id],
          same(commandWorkingDirectorySetting),
        );
        expect(
          assembly.settings.catalog[commandEnvironmentSetting.id],
          same(commandEnvironmentSetting),
        );
        assembly.settings.set(
          commandWorkingDirectorySetting,
          'sub',
          SettingScope.session,
        );
        assembly.settings.set(
          commandPathSetting,
          '/usr/bin:/bin',
          SettingScope.global,
        );
        assembly.settings.set(commandEnvironmentSetting, {
          'BUILD_MODE': 'release',
        }, SettingScope.session);
        expect(tools.commandWorkingDirectory, sub.path);
        expect(tools.osPlan.searchPath, '/usr/bin:/bin');
        expect(tools.osPlan.childEnvironment['BUILD_MODE'], 'release');
        expect(tools.osPlan.outsideEnvironment['BUILD_MODE'], 'release');
        expect(
          tools.osPlan.childEnvironment.containsKey('ANTHROPIC_API_KEY'),
          false,
        );
        await assembly.host.send('record settings');
        final id = assembly.host.session.id;
        assembly.close();
        assembly = create(id: id);
        final resumed = assembly.tools as ToolsPlugin;
        expect(resumed.commandWorkingDirectory, sub.path);
        expect(resumed.osPlan.searchPath, '/usr/bin:/bin');
        expect(resumed.osPlan.childEnvironment['BUILD_MODE'], 'release');
        final sibling = assembly.newSession(null);
        try {
          final other = sibling.tools as ToolsPlugin;
          expect(other.commandWorkingDirectory, workspace.path);
          expect(other.osPlan.searchPath, '/usr/bin:/bin');
          expect(
            other.osPlan.childEnvironment.containsKey('BUILD_MODE'),
            false,
          );
        } finally {
          sibling.close();
        }
        expect(
          () => assembly.settings.set(commandEnvironmentSetting, {
            'MODE': 'debug',
          }, SettingScope.workspace),
          throwsArgumentError,
        );
        for (final value in ['bin:/usr/bin', '/usr/bin::/bin']) {
          expect(
            () => assembly.settings.set(
              commandPathSetting,
              value,
              SettingScope.global,
            ),
            throwsFormatException,
          );
        }
      } finally {
        assembly.close();
        root.deleteSync(recursive: true);
      }
    },
  );
}
