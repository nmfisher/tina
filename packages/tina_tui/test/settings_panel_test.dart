import 'dart:io';
import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart';
import 'package:tina_llm/tina_llm.dart';
import 'package:tina_tui/tina_tui.dart';
import 'app_test.dart' show FakeIo, fakeScreen;
import 'package:tina_tui/src/plugin_catalog.dart' show pluginDescriptions;

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
      {List<ProviderDescriptor> providerDescriptors = descriptors,
      void Function()? applyConfiguration}) async {
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
      final assembly = TuiAssembly.start(
          descriptors: providerDescriptors,
          options: AssemblyOptions(configPath: config.path));
      try {
        final saved = await panel.run(
            applyConfiguration: applyConfiguration,
            path: config.path,
            descriptors: providerDescriptors,
            scopedSettings: assembly.settings,
            settingsBackend: assembly.settingsBackend,
            pluginSettings: assembly.pluginSettings,
            pluginManager: assembly.pluginManager,
            validatePlugins: assembly.validatePlugins,
            pluginDescriptions:
                pluginDescriptions(assembly.pluginSettings.registry));
        expect(index, keys.length);
        return (saved, io.written.toString());
      } finally {
        assembly.close();
      }
    } finally {
      editor.close();
      screen.dispose();
      io.closeInput();
    }
  }

  test('settings edits a masked credential, saves other tables unchanged',
      () async {
    final (saved, output) = await drive([
      CharInput('Providers and models'), enter, // providers
      enter, // Edit Global providers
      ArrowKey(ArrowDirection.right), down, // inline API key
      EditingKey(EditingAction.killToStart), CharInput('new-secret'), enter,
      escape,
    ]);
    expect(saved, isTrue);
    expect(output, isNot(contains('original-secret')));
    expect(output, isNot(contains('new-secret')));
    final loaded =
        loadTinaConfig(path: config.path, descriptors: descriptors).config;
    expect(loaded.providers['custom']!.apiKey, 'new-secret');
    expect(loaded.plugins, legacyProfilePlugins);
    expect(loaded.model, 'original');
  });

  test('settings selects a channel independently of feature plugins', () async {
    final (saved, _) = await drive([
      CharInput('Plugins'), enter, // plugins matrix
      CharInput('Approval'), enter, // approval delivery row
      CharInput('global'), enter, // delivery has no session scope
      CharInput('approvals-stream'), enter, // choice
      escape, escape, // close
    ]);
    expect(saved, true);
    final loaded =
        loadTinaConfig(path: config.path, descriptors: descriptors).config;
    expect(loaded.approvalChannel, 'tina/approvals-stream');
    // The scoped write replaces the legacy enabled list with overrides.
    expect(loaded.plugins, legacyProfilePlugins);
  });

  test('model choices omit disabled models and save the wire ID', () async {
    final (saved, output) = await drive([
      CharInput('Default model'), enter, // default model
      CharInput('global'), enter, // default model has no session scope
      down, enter, // next
      escape, // close
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
      CharInput('global'), enter, // default model has no session scope
      CharInput('Next'),
      enter,
      escape,
    ]);
    expect(saved, true);
    expect(
        loadTinaConfig(path: config.path, descriptors: descriptors)
            .config
            .model,
        'next');
  });

  test('first-run model choice creates config without a stale-file error',
      () async {
    config.deleteSync();
    final (saved, output) = await drive([
      CharInput('Default model'),
      enter,
      CharInput('global'), enter, // default model has no session scope
      CharInput('claude-sonnet-4-6'),
      enter,
      escape,
    ], providerDescriptors: configuredDescriptors());
    expect(saved, true);
    expect(config.existsSync(), true);
    expect(ConfigDocument.open(config.path).table('default')['model'],
        'claude-sonnet-4-6');
    expect(output, isNot(contains('Config changed on disk')));
    expect(output, contains('▸ anthropic/claude-sonnet-4-6'));
  });

  test('cancelling first-run model picker leaves config absent', () async {
    config.deleteSync();
    final (saved, output) = await drive([
      CharInput('Default model'),
      enter,
      escape,
      escape,
    ], providerDescriptors: configuredDescriptors());
    expect(saved, false);
    expect(config.existsSync(), false);
    expect(output, isNot(contains('Could not apply setting')));
  });

  test('the default model picker chooses provider and model together',
      () async {
    config.writeAsStringSync('${config.readAsStringSync()}\n[providers.other]\n'
        'wire = "openai"\nbase_url = "https://other.example/v1"\n'
        'name = "Other Provider"\nmodels = ["org/model|Another model"]\n');
    final (saved, output) = await drive([
      CharInput('Default model'),
      enter,
      CharInput('global'), enter, // default model has no session scope
      CharInput('Other Provider'),
      enter,
      escape,
    ]);
    expect(saved, true);
    final loaded =
        loadTinaConfig(path: config.path, descriptors: descriptors).config;
    expect(loaded.providerId, 'other');
    expect(loaded.model, 'org/model');
    expect(output, contains('Choose default model'));
    expect(output, contains('org/model'));
  });

  test('provider tree checks models and preserves unrelated provider fields',
      () async {
    config.writeAsStringSync(config.readAsStringSync().replaceFirst(
        '[providers.custom]',
        '[providers.custom]\nrequests_per_minute = 7\n'
            'auth_token = "token-secret"\nunknown_option = "keep"'));
    final (saved, output) = await drive([
      CharInput('Providers and models'), enter,
      enter, // Edit Global providers
      ArrowKey(ArrowDirection.right),
      down, down, down, down, // Original (after key, URL, separator)
      CharInput(' '), // disable Original
      down, down, CharInput(' '), // enable Hidden
      enter,
      CharInput('Next'), enter, // choose replacement for disabled default
      escape,
    ]);
    expect(saved, true);
    final document = ConfigDocument.open(config.path);
    final provider = document.table('providers')['custom'] as Map;
    expect(provider['disabled_models'], ['original']);
    expect(provider['requests_per_minute'], 7);
    expect(provider['unknown_option'], 'keep');
    expect(provider['auth_token'], 'token-secret');
    expect(output, isNot(contains('original-secret')));
    expect(output, isNot(contains('token-secret')));
    expect(output, contains('Providers & models'));
  });

  test('Escape discards credential and checkbox changes in the provider tree',
      () async {
    final before = config.readAsStringSync();
    final (saved, _) = await drive([
      CharInput('Providers and models'),
      enter,
      enter, // Edit Global providers
      ArrowKey(ArrowDirection.right),
      down,
      EditingKey(EditingAction.killToStart),
      PasteInput('replacement'),
      escape,
      escape,
    ]);
    expect(saved, false);
    expect(config.readAsStringSync(), before);
  });
  test('plugin checkboxes filter namespaced IDs and save', () async {
    final (saved, _) = await drive([
      CharInput('Plugins'),
      enter,
      ArrowKey(ArrowDirection.right), // workspace column
      ArrowKey(ArrowDirection.right), // global column
      CharInput('tina/pl'),
      CharInput(' '), // enable tina/plans at global scope
      escape,
      escape,
    ]);
    expect(saved, true);
    expect(
        ConfigDocument.open(config.path).table('plugins')['overrides'],
        containsPair('tina/plans', true));
    expect(
        loadTinaConfig(path: config.path, descriptors: descriptors)
            .config
            .plugins,
        [...legacyProfilePlugins, 'tina/plans']);
  });

  test('Enter saves the generation section without a second Save action',
      () async {
    var applications = 0;
    final (saved, output) = await drive([
      ControlKey(ControlCode.tab),
      ControlKey(ControlCode.tab), // file-backed generation edits need global
      CharInput('Generation'),
      enter,
      enter, // custom provider
      CharInput('16384'),
      enter,
      escape,
    ], applyConfiguration: () {
      applications++;
      final loaded =
          loadTinaConfig(path: config.path, descriptors: descriptors).config;
      expect(
          generationFor(loaded, 'custom', 'original').maxOutputTokens, 16384);
    });
    expect(saved, true);
    expect(applications, 1);
    final loaded =
        loadTinaConfig(path: config.path, descriptors: descriptors).config;
    expect(generationFor(loaded, 'custom', 'original').maxOutputTokens, 16384);
    expect(output, contains('Output limit:'));
    expect(output, isNot(contains('thinking_budget')));
    final (_, reopened) = await drive([
      CharInput('Generation'),
      enter,
      enter, // custom provider
      escape,
      escape,
    ]);
    expect(reopened, contains('16,384'));
  });

  for (final applyDraft in [true, false]) {
    test(
        'generation saves inside the provider tree preserve ${applyDraft ? 'applied' : 'cancelled'} credential drafts',
        () async {
      var applications = 0;
      final (saved, _) = await drive([
        CharInput('Providers and models'), enter,
        enter, // Edit Global providers
        ArrowKey(ArrowDirection.right), down,
        EditingKey(EditingAction.killToStart), PasteInput('draft-secret'),
        for (var i = 0; i < 7; i++) down, enter, // advanced provider fields
        CharInput('Generation'), enter, CharInput('16384'), enter,
        escape, // back to the provider tree
        if (applyDraft) ...[
          ArrowKey(ArrowDirection.left), // provider row, Enter applies the tree
          enter,
          escape
        ] else ...[
          escape,
          escape
        ],
      ], applyConfiguration: () {
        applications++;
        final provider =
            loadTinaConfig(path: config.path, descriptors: descriptors)
                .config
                .providers['custom']!;
        expect(provider.maxOutput, 16384);
        if (applications == 1) {
          expect(provider.apiKey, 'original-secret',
              reason: 'credential edits are still a draft');
        }
      });
      expect(saved, true);
      expect(applications, applyDraft ? 2 : 1);
      final provider =
          loadTinaConfig(path: config.path, descriptors: descriptors)
              .config
              .providers['custom']!;
      expect(provider.maxOutput, 16384);
      expect(provider.apiKey, applyDraft ? 'draft-secret' : 'original-secret');
    });
  }

  test('Escape cancels the generation section without touching disk', () async {
    final original = config.readAsStringSync();
    final (saved, _) = await drive([
      ControlKey(ControlCode.tab),
      ControlKey(ControlCode.tab), // file-backed generation edits need global
      CharInput('Generation'),
      enter,
      enter, // custom provider
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
      if (wire != ProviderWire.openAiCompatible) {
        config.writeAsStringSync(config.readAsStringSync().replaceFirst(
            'model = "original"', 'model = "original"\nthinking_budget = 4096'));
      }
      final (saved, _) = await drive([
        ControlKey(ControlCode.tab),
        ControlKey(ControlCode.tab), // file-backed generation edits need global
        CharInput('Generation'), enter,
        enter, // custom provider
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
      if (wire != ProviderWire.openAiCompatible) {
        expect(loaded.thinkingBudget, 4096);
      }
    });
  }

  test(
      'Automatic thinking overrides inherited settings without manual clearing',
      () async {
    config.writeAsStringSync(config.readAsStringSync().replaceFirst(
        'model = "original"', 'model = "original"\nreasoning_effort = "high"'));
    final (saved, _) = await drive([
      ControlKey(ControlCode.tab),
      ControlKey(ControlCode.tab), // file-backed generation edits need global
      CharInput('Generation'), enter,
      enter, // custom provider
      down,
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

  test('generation preserves previously committed model settings', () async {
    final (saved, _) = await drive([
      CharInput('Default model'), enter, // default model picker
      CharInput('global'), enter, // default model has no session scope
      CharInput('Next'), enter, // entry completes; still global, Find cleared
      CharInput('Generation'), enter, enter, // custom provider
      CharInput('16384'), enter,
      escape, // close after committed edits
    ]);
    expect(saved, true);
    final loaded =
        loadTinaConfig(path: config.path, descriptors: descriptors).config;
    expect(loaded.model, 'next');
    expect(loaded.providers['custom']!.maxOutput, 16384);
    expect(loaded.providers['custom']!.apiKey, 'original-secret');
  });

  test('GLM-5.3 shows its actual thinking levels and saves the request value',
      () async {
    config.writeAsStringSync(config
        .readAsStringSync()
        .replaceFirst('model = "original"', 'model = "glm-5.3-flashx"'));
    final (saved, output) = await drive([
      ControlKey(ControlCode.tab),
      ControlKey(ControlCode.tab), // file-backed generation edits need global
      CharInput('Generation'), enter,
      enter, // custom provider
      down,
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
        [
          ControlKey(ControlCode.tab),
          ControlKey(ControlCode.tab), // file-backed generation edits need global
          CharInput('Generation'),
          enter,
          enter, // custom provider
          CharInput('16384'),
          enter,
          escape
        ],
        providerDescriptors: providers);
    var loaded =
        loadTinaConfig(path: config.path, descriptors: providers).config;
    expect(generationFor(loaded, 'custom', 'original').maxOutputTokens, 16384);
    await drive([
      ControlKey(ControlCode.tab),
      ControlKey(ControlCode.tab), // file-backed generation edits need global
      CharInput('Generation'),
      enter,
      enter, // custom provider
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
      ControlKey(ControlCode.tab),
      ControlKey(ControlCode.tab), // file-backed generation edits need global
      CharInput('Generation'),
      enter,
      enter, // custom provider
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

  test('Escape closes settings after accepted edits have saved', () async {
    final before = config.readAsStringSync();
    final (saved, _) =
        await drive([
          CharInput('Default model'),
          enter,
          CharInput('global'), enter, // default model has no session scope
          down,
          enter,
          escape
        ]);
    expect(saved, isTrue);
    expect(config.readAsStringSync(), isNot(before));
    expect(
        loadTinaConfig(path: config.path, descriptors: descriptors)
            .config
            .model,
        'next');
  });

  test('generation edits at the cursor, accepts commas and stores an integer',
      () async {
    final (saved, output) = await drive([
      ControlKey(ControlCode.tab),
      ControlKey(ControlCode.tab), // file-backed generation edits need global
      CharInput('Generation'),
      enter,
      enter, // custom provider
      PasteInput('16,380'),
      ArrowKey(ArrowDirection.left),
      EditingKey(EditingAction.delete),
      CharInput('4'),
      enter,
      escape,
    ]);
    expect(saved, true);
    expect(output, contains('16,384'));
    expect(
        ConfigDocument.open(config.path).table('providers')['custom']
            ['max_output'],
        16384);
  });

  test(
      'real settings reader receives bracketed paste and parks the cursor in the field',
      () async {
    final io = FakeIo();
    final screen = fakeScreen(io);
    final editor = LineEditor(screen: screen);
    final panel = SettingsPanel(screen, editor);
    Future<void> settle() async {
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    Future<void> key(InputEvent event) async {
      editor.inject(event);
      await settle();
    }

    void cursorAt(String visible, int offset) {
      final vt = VirtualTerminal(
          width: screen.layout.width, height: screen.layout.height);
      vt.feed(io.written.toString());
      final rows = List.generate(vt.height, vt.rowText);
      final row = rows.indexWhere((line) => line.contains(visible));
      expect(row, greaterThanOrEqualTo(0));
      expect(vt.cursorVisible, isTrue);
      expect(vt.cursorRow, row);
      expect(vt.cursorCol, rows[row].indexOf(visible) + offset);
    }

    final line = editor.readLine('> ');
    await settle();
    await key(CharInput('preserved draft'));
    final assembly = TuiAssembly.start(
        descriptors: descriptors, options: AssemblyOptions(configPath: config.path));
    final run = panel.run(
        path: config.path,
        descriptors: descriptors,
        scopedSettings: assembly.settings,
        settingsBackend: assembly.settingsBackend);
    void menuCursorHidden() {
      final vt = VirtualTerminal(
          width: screen.layout.width, height: screen.layout.height)
        ..feed(io.written.toString());
      expect(vt.cursorVisible, isFalse);
    }

    try {
      await settle();
      menuCursorHidden();
      screen.chat.writeln('Background output while settings are open');
      screen.input.repaint();
      panel.repaint();
      menuCursorHidden();
      await key(ControlKey(ControlCode.tab));
      await key(ControlKey(ControlCode.tab)); // global scope
      await key(CharInput('Request and token limits'));
      await key(enter);
      await key(CharInput('Turn token'));
      menuCursorHidden();
      await key(enter);
      // The scoped editor seeds the field with the resolved default (0),
      // unlike the legacy raw-table path which left it empty. Clear first.
      await key(EditingKey(EditingAction.killToStart));
      io.feedBytes('\x1b[200~1,234,567\x1b[201~'.codeUnits);
      await settle();
      expect(editor.editState.buffer, 'preserved draft');
      cursorAt('1,234,567', 9);
      await key(EditingKey(EditingAction.home));
      cursorAt('1,234,567', 0);
      await key(ArrowKey(ArrowDirection.right));
      cursorAt('1,234,567', 2); // Skip the displayed separator.
      await key(EditingKey(EditingAction.delete));
      await key(CharInput('9'));
      cursorAt('1,934,567', 3);
      // Resize while editing: the same digit must remain under the cursor.
      io.written.clear();
      screen.resize(ScreenLayout.fromSize(40, 8, split: false));
      editor.handleResize();
      panel.repaint();
      cursorAt('1,934,567', 3);
      await key(enter);
      menuCursorHidden();
      await key(escape);
      // Back through nested menus, without the global double-Esc cancel gesture.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await key(escape);
      expect(await run.timeout(const Duration(seconds: 3)), true);
      expect(
          (VirtualTerminal(
                  width: screen.layout.width, height: screen.layout.height)
                ..feed(io.written.toString()))
              .cursorVisible,
          isTrue);
      expect(
          ConfigDocument.open(config.path).table('limits')['max_turn_tokens'],
          1934567);
      expect(editor.editState.buffer, 'preserved draft');
      await key(enter);
      expect(await line, 'preserved draft');
    } finally {
      panel.cancel();
      assembly.close();
      editor.close();
      screen.dispose();
      io.closeInput();
    }
  });
}
