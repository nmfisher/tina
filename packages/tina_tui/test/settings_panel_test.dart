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

  test('Enter saves the generation section without a second Save action',
      () async {
    final (saved, output) = await drive([
      CharInput('Generation'),
      enter,
      CharInput('16384'),
      enter,
      escape,
    ]);
    expect(saved, true);
    final loaded =
        loadTinaConfig(path: config.path, descriptors: descriptors).config;
    expect(generationFor(loaded, 'custom', 'original').maxOutputTokens, 16384);
    expect(output, contains('Output limit:'));
    expect(output, isNot(contains('thinking_budget')));
    final (_, reopened) = await drive([
      CharInput('Generation'),
      enter,
      escape,
      escape,
    ]);
    expect(reopened, contains('16384'));
  });

  test('Escape cancels the generation section without touching disk', () async {
    final original = config.readAsStringSync();
    final (saved, _) = await drive([
      CharInput('Generation'),
      enter,
      CharInput('32768'),
      down,
      ArrowKey(ArrowDirection.right),
      escape,
      escape,
    ]);
    expect(saved, false);
    expect(config.readAsStringSync(), original);
  });

  for (final wire in ProviderWire.values) {
    test('one Thinking choice replaces incompatible old fields for $wire',
        () async {
      final providers = [
        ProviderDescriptor(
            id: 'custom',
            name: 'Custom',
            wire: wire,
            baseUrl: 'https://custom.example',
            keyEnvVar: 'CUSTOM_API_KEY',
            keyStyle: ProviderKeyStyle.bearer)
      ];
      config.writeAsStringSync(config.readAsStringSync().replaceFirst(
          'model = "original"', 'model = "original"\nthinking_budget = 4096'));
      final (saved, _) = await drive([
        CharInput('Generation'), enter,
        CharInput('16384'), down,
        // OpenAI starts Automatic (legacy numeric budget is unsupported).
        // Other wires display the existing Custom budget, wrapping to Automatic.
        if (wire != ProviderWire.openAiCompatible)
          ArrowKey(ArrowDirection.right),
        ArrowKey(ArrowDirection.right), // Off
        ArrowKey(ArrowDirection.right), // Low
        enter, escape,
      ], providerDescriptors: providers);
      expect(saved, true);
      final loaded =
          loadTinaConfig(path: config.path, descriptors: providers).config;
      final options = generationFor(loaded, 'custom', 'original');
      expect(options.reasoningEffort, 'low');
      expect(options.thinkingBudget, isNull);
      expect(options.maxOutputTokens, 16384);
      // Unrelated global settings remain on disk; this provider overrides them.
      expect(loaded.thinkingBudget, 4096);
    });
  }

  test(
      'Automatic thinking overrides inherited settings without manual clearing',
      () async {
    config.writeAsStringSync(config.readAsStringSync().replaceFirst(
        'model = "original"', 'model = "original"\nreasoning_effort = "high"'));
    final (saved, _) = await drive([
      CharInput('Generation'), enter, down,
      ArrowKey(ArrowDirection.right), // High -> Automatic
      enter, escape,
    ]);
    expect(saved, true);
    final loaded =
        loadTinaConfig(path: config.path, descriptors: descriptors).config;
    final options = generationFor(loaded, 'custom', 'original');
    expect(options.reasoningEffort, isNull);
    expect(options.thinkingBudget, isNull);
  });

  test('saving generation preserves unrelated unsaved settings', () async {
    final (saved, _) = await drive([
      CharInput('Default model'), enter, CharInput('Next'), enter,
      CharInput('Generation'), enter, CharInput('16384'), enter,
      escape, down, enter, // discard the unrelated model draft
    ]);
    expect(saved, true);
    final loaded =
        loadTinaConfig(path: config.path, descriptors: descriptors).config;
    expect(loaded.model, 'original');
    expect(loaded.providers['custom']!.maxOutput, 16384);
    expect(loaded.providers['custom']!.apiKey, 'original-secret');
  });

  test('GLM-5.3 shows its actual thinking levels and saves the request value',
      () async {
    config.writeAsStringSync(config
        .readAsStringSync()
        .replaceFirst('model = "original"', 'model = "glm-5.3-flashx"'));
    final (saved, output) = await drive([
      CharInput('Generation'), enter, down,
      ArrowKey(ArrowDirection.right), // Low, not Off
      ArrowKey(ArrowDirection.right), // High, not Medium
      ArrowKey(ArrowDirection.right), // Max
      enter, escape,
    ]);
    expect(saved, true);
    expect(output, contains('Thinking: Low'));
    expect(output, contains('Thinking: High'));
    expect(output, contains('Thinking: Max'));
    expect(output, isNot(contains('Thinking: Off')));
    expect(output, isNot(contains('Thinking: Medium')));
    final configNow =
        loadTinaConfig(path: config.path, descriptors: descriptors).config;
    final request =
        generationFor(configNow, 'custom', configNow.model).openAi({});
    expect(request['reasoning_effort'], 'max');
    expect(request.containsKey('thinking_budget'), false);
  });

  test('an explicit limit wins over model metadata; Automatic restores it',
      () async {
    const providers = [
      ProviderDescriptor(
          id: 'custom',
          name: 'Custom',
          wire: ProviderWire.openAiCompatible,
          baseUrl: 'https://custom.example',
          keyEnvVar: 'CUSTOM_API_KEY',
          keyStyle: ProviderKeyStyle.bearer,
          models: {
            'original': ModelInfo(
                id: 'original',
                name: 'Original',
                contextWindow: 1000000,
                maxOutput: 32768,
                supportsTools: true)
          })
    ];
    await drive(
        [CharInput('Generation'), enter, CharInput('16384'), enter, escape],
        providerDescriptors: providers);
    var loaded =
        loadTinaConfig(path: config.path, descriptors: providers).config;
    expect(generationFor(loaded, 'custom', 'original').maxOutputTokens, 16384);
    await drive([
      CharInput('Generation'),
      enter,
      EditingKey(EditingAction.killToStart),
      enter,
      escape
    ], providerDescriptors: providers);
    loaded = loadTinaConfig(path: config.path, descriptors: providers).config;
    expect(generationFor(loaded, 'custom', 'original').maxOutputTokens, 32768);
  });

  test('Automatic output clears the override and uses the resolved default',
      () async {
    config.writeAsStringSync(config.readAsStringSync().replaceFirst(
        '[providers.custom]', '[providers.custom]\nmax_output = 16384'));
    final (saved, _) = await drive([
      CharInput('Generation'),
      enter,
      EditingKey(EditingAction.killToStart),
      enter,
      escape,
    ]);
    expect(saved, true);
    final loaded =
        loadTinaConfig(path: config.path, descriptors: descriptors).config;
    expect(loaded.providers['custom']!.maxOutput, isNull);
    expect(generationFor(loaded, 'custom', 'original').maxOutputTokens, 8192);
  });

  test('Escape requires an explicit discard before dropping edits', () async {
    final before = config.readAsStringSync();
    final (saved, _) =
        await drive([down, enter, down, enter, escape, down, enter]);
    expect(saved, isFalse);
    expect(config.readAsStringSync(), before);
  });
}
