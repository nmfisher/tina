import 'dart:io';
import 'package:classification/plugin.dart';
import 'package:test/test.dart';
import 'package:tina_classification_tui/tina_classification_tui.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina/src/console_catalog.dart';
import 'package:tina_tui/tina_tui.dart';
import 'package:tina/session.dart';
import 'package:tina/tui.dart';
import 'app_test.dart' show FakeIo, fakeScreen;
import 'turn_rendering_test.dart' show waitFor;

void main() {
  late Directory root;
  setUp(() =>
      root = Directory.systemTemp.createTempSync('classification-views-'));
  tearDown(() => root.deleteSync(recursive: true));

  SessionAssembly assemble({bool panels = false}) => SessionAssembly.start(
        options: AssemblyOptions(
            configPath: '${root.path}/config',
            workingDirectory: root.path,
            plugins: [
              'tina/classification',
              'tina/chat-tui',
              if (panels) 'tina/panels-tui'
            ]),
        providerFactory: (_) => ScriptedProvider([]),
      );

  test('factories and inspection commands are scoped to each view', () async {
    final assembly = assemble();
    addTearDown(assembly.close);
    final feature =
        assembly.host.plugins.whereType<ClassificationPlugin>().single;
    expect(feature, isNot(isA<ConsoleContribution>()));
    final connection = assembly.host.connect();
    addTearDown(connection.close);
    final command = assembly.commands['classification'];
    final first = createConsoleView(feature) as ClassificationView;
    final second = createConsoleView(feature) as ClassificationView;
    expect(first, isNot(same(second)));
    expect(first.classification, same(second.classification));
    final inputs = [FakeIo(), FakeIo()];
    final screens = inputs.map(fakeScreen).toList();
    final editors =
        screens.map((screen) => LineEditor(screen: screen)).toList();
    final attachments = [
      ConsoleAttachment.attach(
          first, ConsoleContext(screen: screens[0], editor: editors[0])),
      ConsoleAttachment.attach(
          second, ConsoleContext(screen: screens[1], editor: editors[1])),
    ];
    addTearDown(() {
      for (final attachment in attachments) attachment.dispose();
      for (final editor in editors) editor.close(reportLatency: false);
      for (final screen in screens) screen.dispose();
      for (final input in inputs) input.closeInput();
    });
    await offerConsoleCommand(
        connection, [attachments.first], '/classification hierarchy')!;
    expect(first.panel!.hierarchy, isTrue);
    expect(second.panel!.hierarchy, isFalse);
    expect(second.panel!.regionVisible, isFalse);
    expect(assembly.commands['classification'], same(command));
    expect(
        offerConsoleCommand(
            connection, attachments, '/classification categories'),
        isNull);
    expect(
        offerConsoleCommand(connection, attachments, '/classification',
            whileRunning: true),
        isNull);
    expect(offerConsoleCommand(connection, attachments, '/unknown'), isNull);
    expect(
        offerConsoleCommand(connection, attachments, 'classification'), isNull);
    attachments.first.dispose();
    expect(
        offerConsoleCommand(connection, [attachments.first], '/classification'),
        isNull);
    await offerConsoleCommand(
        connection, [attachments.last], '/classification')!;
    expect(second.panel!.regionVisible, isTrue);
    expect(
        assembly.host.plugins.whereType<ClassificationPlugin>(), hasLength(1));
  });

  test(
      'SessionView submission opens its local inspector; headless prints status',
      () async {
    final session = TuiSession.wrap(assemble());
    final view = session.createView();
    final input = FakeIo();
    final screen = fakeScreen(input);
    final editor = LineEditor(screen: screen);
    addTearDown(() {
      view.detachConsole();
      session.close();
      editor.close(reportLatency: false);
      screen.dispose();
      input.closeInput();
    });
    view.attachConsole(ConsoleContext(screen: screen, editor: editor));
    await view.submit('/classification hierarchy');
    expect(input.written.toString(), contains('classification · hierarchy'));
    await view.submit('/classification categories');
    expect(input.written.toString(), contains('selections'));
    view.detachConsole();
    final output = <String>[];
    (session.terminal as SessionTerminal).onLine = output.add;
    await session.runLine('/classification');
    expect(output.single, 'Classification: no input classified yet');
  });

  for (final panels in [false, true]) {
    test('inspection commands and live reload work (workspace: $panels)',
        () async {
      final assembly = assemble(panels: panels);
      final original =
          assembly.host.plugins.whereType<ClassificationPlugin>().single;
      final input = FakeIo();
      final screen = fakeScreen(input);
      late LineEditor editor;
      final done = runTui(TuiSession.wrap(assembly),
          screen: screen,
          editorFor: (screen) => editor =
              LineEditor(screen: screen, escapeTimeout: Duration.zero));
      addTearDown(() async {
        input.feedBytes('\x03\x03\x03'.codeUnits);
        input.closeInput();
        await done.timeout(const Duration(seconds: 5));
      });
      String visible() {
        final terminal = VirtualTerminal(
            width: screen.layout.width, height: screen.layout.height)
          ..feed(input.written.toString());
        return List.generate(screen.layout.height, terminal.rowText).join('\n');
      }

      await waitFor(() => input.written.isNotEmpty);
      input.feedBytes('/classification hierarchy\r'.codeUnits);
      await waitFor(() => visible().contains('classification · hierarchy'));
      expect(visible(), contains('no input classified yet'));
      if (panels) editor.inject(EscapeKey());
      input.feedBytes('/classification categories\r'.codeUnits);
      await waitFor(() => input.written.toString().contains('selections'));
      assembly.pluginSettings.apply('tina/classification', false,
          PluginScope.session, assembly.pluginManager);
      expect(assembly.pluginManager.lastError, isNull);
      expect(assembly.commands['classification'], isNull);
      expect(visible(), isNot(contains('classification · hierarchy')));
      assembly.pluginSettings.apply('tina/classification', true,
          PluginScope.session, assembly.pluginManager);
      expect(assembly.pluginManager.lastError, isNull);
      final restored =
          assembly.host.plugins.whereType<ClassificationPlugin>().single;
      expect(restored, isNot(same(original)));
      expect(restored, isNot(isA<ConsoleContribution>()));
      restored.trace
          .begin(inputId: 'reloaded', title: 'Reloaded stage', request: {});
      await waitFor(() => visible().contains('Reloaded stage'));
      expect(visible(), isNot(contains('classification · hierarchy')));
      input.feedBytes('/classification hierarchy\r'.codeUnits);
      await waitFor(() => visible().contains('classification · hierarchy'));
      if (panels) editor.inject(EscapeKey());
      input.feedBytes('/quit\r'.codeUnits);
      expect(await done, 0);
    });
  }
}
