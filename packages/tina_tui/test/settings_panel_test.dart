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

  Future<(bool, String)> drive(List<InputEvent> keys,
      {List<ProviderDescriptor> providerDescriptors = descriptors}) async {
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
          descriptors: providerDescriptors,
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
      CharInput('Approval channel'), enter, // approval channel
      EditingKey(EditingAction.killToStart), CharInput('tina/approvals-stream'),
      enter, escape,
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
  test('plugin checkboxes filter namespaced IDs and save', () async {
    final (saved, _) = await drive([
      CharInput('Plugins'),
      enter,
      CharInput('tina/pl'),
      CharInput(' '),
      escape,
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

  test('Escape offers saving; generation values survive reopening', () async {
    const gemini = [
      ProviderDescriptor(
          id: 'custom',
          name: 'Custom',
          wire: ProviderWire.gemini,
          baseUrl: 'https://custom.example',
          keyEnvVar: 'CUSTOM_API_KEY',
          keyStyle: ProviderKeyStyle.header)
    ];
    final (saved, output) = await drive([
      CharInput('Generation'), enter,
      CharInput('max_tokens'), enter, CharInput('16384'), enter,
      CharInput('Generation'), enter,
      CharInput('thinking_budget'), enter, CharInput('4096'), enter,
      escape, enter, // Save changes and close
    ], providerDescriptors: gemini);
    expect(saved, true);
    expect(output, contains('Unsaved settings'));
    final loaded =
        loadTinaConfig(path: config.path, descriptors: gemini).config;
    expect(loaded.maxOutputTokens, 16384);
    expect(loaded.thinkingBudget, 4096);
    final (_, reopened) = await drive([
      CharInput('Generation'),
      enter,
      CharInput('max_tokens'),
      escape,
      CharInput('Generation'),
      enter,
      CharInput('thinking_budget'),
      escape,
      escape,
    ], providerDescriptors: gemini);
    expect(reopened, contains('max_tokens: 16384'));
    expect(reopened, contains('thinking_budget: 4096'));
  });

  test('unsupported thinking budget cannot invalidate the output-token save',
      () async {
    final (saved, output) = await drive([
      CharInput('Generation'), enter,
      CharInput('max_tokens'), enter, CharInput('16384'), enter,
      CharInput('Generation'), enter,
      CharInput('thinking_budget'), enter,
      enter, // Use reasoning_effort instead
      CharInput('low'), enter,
      CharInput('Save'), enter,
    ]);
    expect(saved, true);
    expect(output, contains('thinking_budget is unsupported'));
    final loaded =
        loadTinaConfig(path: config.path, descriptors: descriptors).config;
    expect(loaded.maxOutputTokens, 16384);
    expect(loaded.thinkingBudget, isNull);
    expect(loaded.reasoningEffort, 'low');
  });

  test('canceling the exit question preserves the draft', () async {
    final (saved, _) = await drive([
      CharInput('Generation'), enter,
      CharInput('max_tokens'), enter, CharInput('2048'), enter,
      escape, escape, // keep editing
      CharInput('Save'), enter,
    ]);
    expect(saved, true);
    expect(
        loadTinaConfig(path: config.path, descriptors: descriptors)
            .config
            .maxOutputTokens,
        2048);
  });

  test('Escape requires an explicit discard before dropping edits', () async {
    final before = config.readAsStringSync();
    final (saved, _) =
        await drive([down, enter, down, enter, escape, down, enter]);
    expect(saved, isFalse);
    expect(config.readAsStringSync(), before);
  });
}
