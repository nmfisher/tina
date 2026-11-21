@Tags(['wasm-runtime'])
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tina/src/app_io.dart';
import 'package:tina_settings/tina_settings.dart';
import 'package:tina_wasm/src/preloaded_app_io.dart';

void main() {
  test('the Wasm endpoint follows the selected global provider', () {
    expect(wasmProviderEndpoint({
      'default': {'provider': 'private'},
      'providers': {
        'private': {'base_url': 'https://private.example/v1'},
        'other': {'base_url': 'https://other.example/v1'},
      },
    }, {}), 'https://private.example/v1');
    expect(() => wasmProviderEndpoint({'default': {'provider': 'private'}}, {}),
        throwsStateError);
  });

  test('Wasm settings read and write scoped IDs as valid TOML', () {
    final directory = Directory.systemTemp.createTempSync(
      'tina-wasm-settings-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final global = File('${directory.path}/global.toml')
      ..writeAsStringSync('[example]\nname = "世界"\n[unrelated]\nkeep = true\n');
    final workspace = File('${directory.path}/workspace.toml')
      ..writeAsStringSync('''
[plugin_config."tina/mode"]
classifier_instruction = "untrusted workspace text"
''');
    final catalog = SettingCatalog()
      ..register(
        SettingDefinition<String>(
          id: 'test/example/name',
          label: 'Name',
          description: 'A name',
          defaultValue: '',
          kind: SettingKind.text,
          configPath: ['example', 'name'],
        ),
      )
      ..register(
        SettingDefinition<String>(
          id: 'tina/mode/classifier_instruction',
          label: 'Instructions',
          description: 'Approval preferences',
          defaultValue: '',
          kind: SettingKind.text,
          configPath: ['plugin_config', 'tina/mode', 'classifier_instruction'],
        ),
      );
    final backend = PreloadedSettingsBackend(
      defaultAppIo(),
      globalPath: global.path,
      workspacePath: workspace.path,
    )..bindCatalog(catalog);
    expect(backend.read(SettingScope.global), {'test/example/name': '世界'});
    expect(backend.read(SettingScope.workspace), isEmpty);
    backend.write(SettingScope.global, {'test/example/name': 'é'});
    expect(backend.read(SettingScope.global), {'test/example/name': 'é'});
    expect(backend.document(SettingScope.global)['unrelated'], {'keep': true});
  });

}
