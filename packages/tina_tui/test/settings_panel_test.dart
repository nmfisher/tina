import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_llm/tina_llm.dart';
import 'package:tina_tui/tina_tui.dart';
import 'app_test.dart' show FakeIo, fakeScreen;

const descriptors = [
  ProviderDescriptor(
      id: 'custom',
      name: 'Custom',
      wire: ProviderWire.openAiCompatible,
      baseUrl: 'https://custom.example',
      keyEnvVar: 'CUSTOM_API_KEY',
      keyStyle: ProviderKeyStyle.bearer)
];

void main() {
  late Directory directory;
  late File config;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('tina-settings-');
    config = File('${directory.path}/config')..writeAsStringSync('''
[default]
provider = "custom"
model = "original"
[providers.custom]
api_key = "original-secret"
models = ["original|Original", "next|Next", "hidden|Hidden"]
disabled_models = ["hidden"]
[plugins]
enabled = []
''');
  });
  tearDown(() => directory.deleteSync(recursive: true));
  final enter = ControlKey(ControlCode.enter);
  final down = ArrowKey(ArrowDirection.down);
  final escape = EscapeKey();

  Future<(bool, String)> drive(List<InputEvent> keys) async {
    final io = FakeIo();
    final screen = fakeScreen(io);
    screen.resize(ScreenLayout.fromSize(40, 8, split: false));
    final editor = LineEditor(screen: screen);
    var index = 0;
    late final SettingsPanel panel;
    panel = SettingsPanel(screen, editor, readEvent: () async {
      if (index >= keys.length)
        fail('settings consumed more keys than expected');
      // Reflow every other key to exercise selection and edit preservation.
      screen.resize(ScreenLayout.fromSize(
          index.isEven ? 40 : 80, index.isEven ? 8 : 10,
          split: false));
      panel.repaint();
      return keys[index++];
    });
    try {
      final saved = await panel.run(
          path: config.path,
          descriptors: descriptors,
          pluginIds: ['tina/plans', 'tina/goals']);
      expect(index, keys.length);
      return (saved, io.written.toString());
    } finally {
      editor.close();
      screen.dispose();
      io.closeInput();
    }
  }

  test('settings edits a masked credential, saves other tables unchanged',
      () async {
    final (saved, output) = await drive([
      down, down, enter, // providers
      enter, // custom
      down, down, down, enter, // API key
      EditingKey(EditingAction.killToStart), CharInput('new-secret'), enter,
      escape, escape, // back to root
      down, down, down, down, enter, // save
    ]);
    expect(saved, isTrue);
    expect(output, isNot(contains('original-secret')));
    expect(output, isNot(contains('new-secret')));
    final loaded =
        loadTinaConfig(path: config.path, descriptors: descriptors).config;
    expect(loaded.providers['custom']!.apiKey, 'new-secret');
    expect(loaded.plugins, isEmpty);
    expect(loaded.model, 'original');
  });

  test('settings selects a channel independently of feature plugins', () async {
    final (saved, _) = await drive([
      down, down, down, enter, // plugins
      down, enter, // approval channel
      EditingKey(EditingAction.killToStart), CharInput('tina/approvals-stream'),
      enter,
      down, down, down, down, enter, // save
    ]);
    expect(saved, true);
    final loaded =
        loadTinaConfig(path: config.path, descriptors: descriptors).config;
    expect(loaded.approvalChannel, 'tina/approvals-stream');
    expect(loaded.plugins, isEmpty);
  });

  test('model choices omit disabled models and save the wire ID', () async {
    final (saved, output) = await drive([
      down, enter, // default model
      down, enter, // next
      down, down, down, down, enter, // save
    ]);
    expect(saved, isTrue);
    expect(output, isNot(contains('Hidden')));
    expect(
        loadTinaConfig(path: config.path, descriptors: descriptors)
            .config
            .model,
        'next');
  });

  test('menus filter models and root actions by typing', () async {
    final (saved, _) = await drive([
      CharInput('Default model'),
      enter,
      CharInput('Next'),
      enter,
      CharInput('Save'),
      enter,
    ]);
    expect(saved, true);
    expect(
        loadTinaConfig(path: config.path, descriptors: descriptors)
            .config
            .model,
        'next');
  });
  test('plugin fields complete namespaced IDs with Tab', () async {
    final (saved, _) = await drive([
      CharInput('Plugins'),
      enter,
      enter,
      CharInput('tina/pl'),
      ControlKey(ControlCode.tab),
      enter,
      CharInput('Save'),
      enter,
    ]);
    expect(saved, true);
    expect(
        loadTinaConfig(path: config.path, descriptors: descriptors)
            .config
            .plugins,
        ['tina/plans']);
  });
  test('numeric generation setting saves as an integer', () async {
    final (saved, _) = await drive([
      CharInput('Generation'),
      enter,
      CharInput('max_tokens'),
      enter,
      CharInput('2048'),
      enter,
      CharInput('Save'),
      enter,
    ]);
    expect(saved, true);
    expect(
        loadTinaConfig(path: config.path, descriptors: descriptors)
            .config
            .maxOutputTokens,
        2048);
  });

  test('Escape discards edits without writing', () async {
    final before = config.readAsStringSync();
    final (saved, _) = await drive([down, enter, down, enter, escape]);
    expect(saved, isFalse);
    expect(config.readAsStringSync(), before);
  });
}
