import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_plans/tina_plans.dart';
import 'package:tina_plans_tui/tina_plans_tui.dart';
import 'package:tina_tui/src/console_catalog.dart';
import 'package:tina_tui/tina_tui.dart';

import 'app_test.dart' show FakeIo, fakeScreen;
import 'turn_rendering_test.dart' show waitFor;

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('plans-views-'));
  tearDown(() => root.deleteSync(recursive: true));

  TuiAssembly assemble({bool panels = false, bool chat = false}) =>
      TuiAssembly.start(
        options: AssemblyOptions(
          configPath: '${root.path}/config',
          workingDirectory: root.path,
          plugins: [
            'tina/plans',
            if (chat) 'tina/chat-tui',
            if (panels) 'tina/panels-tui',
          ],
        ),
        providerFactory: (_) => ScriptedProvider([]),
      );

  test('presentation factories share one runtime plans feature', () async {
    final assembly = assemble();
    addTearDown(assembly.close);
    final feature = assembly.host.plugins.whereType<PlansPlugin>().single;
    expect(feature, isNot(isA<ConsoleContribution>()));
    expect(assembly.commands['plan'], isNotNull);
    final first = createConsoleView(feature) as PlansView;
    final second = createConsoleView(feature) as PlansView;
    expect(first, isNot(same(second)));
    expect(first.plans, same(second.plans));
    final inputs = [FakeIo(), FakeIo()];
    final screens = inputs.map(fakeScreen).toList();
    final editors =
        screens.map((screen) => LineEditor(screen: screen)).toList();
    final attachments = [
      for (var i = 0; i < 2; i++)
        ConsoleAttachment.attach(i == 0 ? first : second,
            ConsoleContext(screen: screens[i], editor: editors[i])),
    ];
    addTearDown(() {
      for (final attachment in attachments) attachment.dispose();
      for (final editor in editors) editor.close(reportLatency: false);
      for (final screen in screens) screen.dispose();
      for (final input in inputs) input.closeInput();
    });
    await feature.execute({
      'items': [
        {'text': 'shared plan', 'state': 'pending'}
      ],
    });
    await pumpEventQueue();
    for (final input in inputs) {
      expect(input.written.toString(), contains('shared plan'));
    }
    attachments.first.dispose();
    await feature.execute({
      'items': [
        {'text': 'still running', 'state': 'done'}
      ],
    });
    await pumpEventQueue();
    expect(inputs.last.written.toString(), contains('still running'));
    expect(inputs.first.written.toString(), isNot(contains('still running')));
    expect(assembly.host.plugins.whereType<PlansPlugin>(), hasLength(1));
    expect(assembly.host.session.loop.log.where(PlanChangedEntry.matches),
        hasLength(2));
  });

  for (final panels in [false, true]) {
    test('plans views attach, unload and reload (workspace: $panels)',
        () async {
      final assembly = assemble(panels: panels, chat: true);
      final feature = assembly.host.plugins.whereType<PlansPlugin>().single;
      await feature.execute({
        'items': [
          {'text': 'startup plan', 'state': 'pending'}
        ],
      });
      final input = FakeIo();
      final screen = fakeScreen(input);
      final done = runApp(TuiSession.wrap(assembly), screen: screen);
      addTearDown(() async {
        input.closeInput();
        await done;
      });
      VirtualTerminal terminal() => VirtualTerminal(
          width: screen.layout.width, height: screen.layout.height)
        ..feed(input.written.toString());
      String visible() =>
          List.generate(screen.layout.height, terminal().rowText).join('\n');
      String status() => terminal().rowText(screen.layout.stripRow);

      await waitFor(() => visible().contains('startup plan'));
      expect(status(), contains('plan: 0/1 done'));
      expect(RegExp('plan:').allMatches(status()), hasLength(1));
      assembly.pluginSettings.apply(
          'tina/plans', false, PluginScope.session, assembly.pluginManager);
      expect(assembly.pluginManager.lastError, isNull);
      expect(assembly.commands['plan'], isNull);
      expect(visible(), isNot(contains('startup plan')));
      expect(status(), isNot(contains('plan:')));
      expect(status(), contains('Σ 0'));
      assembly.pluginSettings.apply(
          'tina/plans', true, PluginScope.session, assembly.pluginManager);
      expect(assembly.pluginManager.lastError, isNull);
      expect(assembly.commands['plan'], isNotNull);
      await waitFor(() => visible().contains('startup plan'));
      expect(RegExp('plan:').allMatches(status()), hasLength(1));
      final restored = assembly.host.plugins.whereType<PlansPlugin>().single;
      expect(restored, isNot(same(feature)));
      expect(restored, isNot(isA<ConsoleContribution>()));
      await restored.execute({
        'items': [
          {'text': 'reloaded plan', 'state': 'done'}
        ],
      });
      await waitFor(() => visible().contains('reloaded plan'));
      expect(status(), contains('plan: 1/1 done'));
      expect(assembly.host.session.loop.log.where(PlanChangedEntry.matches),
          hasLength(2));
      input.feedBytes('/quit\r'.codeUnits);
      expect(await done, 0);
    });
  }
}
