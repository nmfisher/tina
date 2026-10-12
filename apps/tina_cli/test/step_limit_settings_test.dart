import 'package:tina_settings/tina_settings.dart';
import 'package:tina/src/config_settings_management.dart';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_step_limit/tina_step_limit.dart';
import 'package:tina/src/console_catalog.dart';
import 'package:tina_tui/tina_tui.dart';
import 'package:tina/session.dart';
import 'package:tina/tui.dart';
import 'app_test.dart' show FakeIo, fakeScreen;
import 'turn_rendering_test.dart' show ControlledProvider, waitFor;

final class _Presentation {
  final io = FakeIo();
  late final screen = fakeScreen(io);
  late final editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
  late final context = ConsoleContext(screen: screen, editor: editor);
  bool _disposed = false;

  Future<bool> setting(SessionAssembly assembly, List<InputEvent> events) async {
    final keys = [...events];
    final saved =
        await SettingsPanel(screen, editor, readEvent: () async => keys.removeAt(0))
            .run(
                sections: context.settings,
                management: ConfigSettingsManagement(
                  scopedSettings: assembly.settings,
                  backend: assembly.settingsBackend,
                  pluginSettings: assembly.pluginSettings,
                  pluginManager: assembly.pluginManager,
                ));
    expect(keys, isEmpty);
    return saved;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    editor.close(reportLatency: false);
    screen.dispose();
    io.closeInput();
  }
}

void main() {
  late Directory root;
  late File config, target;
  final enter = ControlKey(ControlCode.enter), escape = EscapeKey();
  final tab = ControlKey(ControlCode.tab);
  final clear = EditingKey(EditingAction.killToStart);
  setUp(() {
    root = Directory.systemTemp.createTempSync('step-limit-settings-');
    config = File('${root.path}/config')
      ..writeAsStringSync('[default]\nmodel = "fixture"\n'
          '[legacy_extension]\nvalue = "preserve me"\n');
    target = File('${root.path}/sample.txt')
      ..writeAsStringSync('fixture content');
  });
  tearDown(() => root.deleteSync(recursive: true));

  SessionAssembly assemble(LlmProvider provider, {bool panels = false}) =>
      SessionAssembly.start(
        options: AssemblyOptions(
            configPath: config.path,
            workingDirectory: root.path,
            plugins: [
              'tina/chat-tui',
              'tina/step-limit',
              if (panels) 'tina/panels-tui'
            ]),
        providerFactory: (_) => provider,
      );

  List<InputEvent> edit(String value,
          {SettingScope scope = SettingScope.session, bool cancel = false}) =>
      [
        for (var i = 0; i < scope.index; i++) tab,
        CharInput('Model rounds per turn'),
        enter,
        clear,
        CharInput(value),
        cancel ? escape : enter,
        escape,
      ];

  List<StreamEvent> readRound(String id) => scriptedReply('', calls: [
        ToolUseBlock(id: id, name: 'read', input: {'filePath': target.path}),
      ]);

  test('independent settings editors preserve scoped values and validation',
      () async {
    final assembly = assemble(ScriptedProvider([]));
    addTearDown(assembly.close);
    final policy = assembly.host.plugins.whereType<StepLimitPlugin>().single;
    expect(policy, isNot(isA<ConsoleContribution>()));
    expect(createConsoleView(policy), isNull);
    final first = _Presentation(), second = _Presentation();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    expect(
        await first.setting(assembly, edit('32', scope: SettingScope.global)),
        isTrue);
    expect(assembly.settings.read(stepLimitSetting).value, 32);
    expect(StepLimitConfig(config.path).read(), 32);
    expect(config.readAsStringSync(), contains('preserve me'));
    expect(first.io.written.toString(), contains('[global]'));
    final saved = config.readAsStringSync();
    for (final invalid in ['-1', '1.5']) {
      expect(
          await second.setting(assembly, edit(invalid, cancel: true)), isFalse);
      expect(assembly.settings.read(stepLimitSetting).value, 32);
      expect(config.readAsStringSync(), saved);
    }
    expect(second.io.written.toString(), contains('nonnegative integer'));
    expect(await second.setting(assembly, edit('7')), isTrue);
    expect(assembly.settings.read(stepLimitSetting).value, 7);
    expect(StepLimitConfig(config.path).read(), 32);
    first.dispose();
    expect(
        await second.setting(
            assembly, edit('4', scope: SettingScope.workspace)),
        isTrue);
    expect(assembly.settings.read(stepLimitSetting).value, 7);
    assembly.settings.removeOverride(stepLimitSetting, SettingScope.session);
    expect(assembly.settings.read(stepLimitSetting).value, 4);
    expect(assembly.host.plugins.whereType<StepLimitPlugin>().single,
        same(policy));
    expect(first.context.settings.sections, isEmpty);
    expect(second.context.settings.sections, isEmpty);
  });

  test('detaching and reattaching preserves the active allowance and counter',
      () async {
    final provider = ControlledProvider();
    final session = TuiSession.wrap(assemble(provider));
    final policy = session.host.plugins.whereType<StepLimitPlugin>().single;
    session.assembly.settings.set(stepLimitSetting, 2, SettingScope.session);
    final view = session.createView();
    final first = _Presentation(), replacement = _Presentation();
    Future<bool>? work;
    addTearDown(() async {
      session.cancel();
      if (work != null) await work.timeout(const Duration(seconds: 3));
      view.detachConsole();
      session.close();
      replacement.dispose();
      first.dispose();
    });
    view.attachConsole(first.context);
    work = session.runLine('first', renderReply: false);
    await waitFor(() => provider.requests.length == 1);
    view.detachConsole();
    expect(session.host.session.loop.running, isTrue);
    expect(await replacement.setting(session.assembly, edit('1')), isTrue);
    for (final event in readRound('first-read'))
      provider.requests[0].add(event);
    await provider.requests[0].close();
    await waitFor(() => provider.requests.length == 2);
    view.attachConsole(replacement.context);
    for (final event in readRound('second-read'))
      provider.requests[1].add(event);
    await provider.requests[1].close();
    await work;
    expect(provider.requests, hasLength(2));
    expect(session.host.session.turns.single.detail, contains('limit (2)'));
    expect(
        session.host.session.loop.log
            .whereType<MessageAppendedEntry>()
            .expand((entry) => entry.message.content)
            .whereType<ToolResultBlock>(),
        hasLength(2));
    expect(
        session.host.plugins.whereType<StepLimitPlugin>().single, same(policy));
    work = session.runLine('next', renderReply: false);
    await waitFor(() => provider.requests.length == 3);
    for (final event in readRound('next-read')) provider.requests[2].add(event);
    await provider.requests[2].close();
    await work;
    expect(provider.requests, hasLength(3));
    expect(session.host.session.turns.last.detail, contains('limit (1)'));
  });

  for (final panels in [false, true]) {
    test('plain runtime policy unloads and reloads (workspace: $panels)',
        () async {
      final provider = ScriptedProvider([
        readRound('first-read'),
        scriptedReply('unlimited after unload'),
        readRound('reloaded-read'),
        scriptedReply('unreachable'),
      ]);
      final assembly = assemble(provider, panels: panels);
      assembly.settings.set(stepLimitSetting, 1, SettingScope.session);
      final original =
          assembly.host.plugins.whereType<StepLimitPlugin>().single;
      final session = TuiSession.wrap(assembly);
      final io = FakeIo();
      late LineEditor editor;
      final done = runTui(session,
          screen: fakeScreen(io),
          editorFor: (screen) => editor = LineEditor(screen: screen));
      addTearDown(() async {
        session.cancel();
        io.feedBytes('\x03\x03\x03'.codeUnits);
        io.closeInput();
        await done.timeout(const Duration(seconds: 5));
      });
      await waitFor(() => editor.isEditing);
      io.feedBytes('first\r'.codeUnits);
      await waitFor(() =>
          session.host.session.turns.length == 1 &&
          !session.host.session.loop.running);
      expect(session.host.session.turns.last.detail, contains('limit (1)'));
      assembly.pluginSettings.apply('tina/step-limit', false,
          PluginScope.session, assembly.pluginManager);
      expect(assembly.pluginManager.lastError, isNull);
      expect(assembly.host.plugins.whereType<StepLimitPlugin>(), isEmpty);
      expect(assembly.settings.catalog[stepLimitSetting.id],
          same(stepLimitSetting));
      io.feedBytes('second\r'.codeUnits);
      await waitFor(() =>
          session.host.session.turns.length == 2 &&
          !session.host.session.loop.running);
      expect(session.host.session.turns.last.stopReason, StopReason.complete);
      assembly.pluginSettings.apply(
          'tina/step-limit', true, PluginScope.session, assembly.pluginManager);
      expect(assembly.pluginManager.lastError, isNull);
      final restored =
          assembly.host.plugins.whereType<StepLimitPlugin>().single;
      expect(restored, isNot(same(original)));
      expect(restored, isNot(isA<ConsoleContribution>()));
      expect(createConsoleView(restored), isNull);
      io.feedBytes('third\r'.codeUnits);
      await waitFor(() =>
          session.host.session.turns.length == 3 &&
          !session.host.session.loop.running);
      expect(session.host.session.turns.last.detail, contains('limit (1)'));
      expect(provider.callCount, 3);
      io.feedBytes('/quit\r'.codeUnits);
      expect(await done, 0);
    });
  }
}
