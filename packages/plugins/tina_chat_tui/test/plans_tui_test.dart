import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_plans/tina_plans.dart';
import 'package:tina_chat_tui/tina_chat_tui.dart';
import 'console_test.dart' show Io;

class Panels implements ConsolePanels {
  Future<void> spawn([String? model]) async {}
  Future<void> closeFocused() async {}
  List<String> describe() => [];
}

void main() {
  late Io io;
  late Screen screen;
  late LineEditor editor;
  late PlansConsolePlugin plugin;
  late AgentLoop loop;
  late bool active;
  String visible() {
    final vt = VirtualTerminal(
        width: screen.layout.width, height: screen.layout.height)
      ..feed(io.output.toString());
    return List.generate(screen.layout.height, vt.rowText).join('\n');
  }

  setUp(() {
    active = true;
    io = Io();
    screen =
        Screen(io: io, layout: ScreenLayout.fromSize(80, 24, split: false));
    editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
    plugin = PlansConsolePlugin();
    loop = AgentLoop(provider: ScriptedProvider([]), plugins: [plugin]);
    plugin.mountOn(loop);
    plugin.attachConsole(ConsoleContext(screen: screen, editor: editor).forView(
        chat: screen.chat,
        isActive: () => active,
        activate: () {},
        panels: Panels()));
  });
  tearDown(() {
    plugin.closeSession();
    editor.close(reportLatency: false);
    screen.dispose();
    unawaited(io.input.close());
  });
  test('live progress, child folding, visibility, clear and detach', () async {
    plugin.store.update(loop, [
      const PlanEntryItem('implement', state: 'in_progress', children: [
        PlanEntryItem('read', state: 'done'),
        PlanEntryItem('test', state: 'pending'),
      ]),
    ]);
    plugin.repaintConsole();
    expect(visible(), contains('plan · 1/3'));
    expect(visible(), contains('· test'));
    plugin.overlay!.focus();
    plugin.overlay!.handleEvent(ControlKey(ControlCode.enter));
    expect(visible(), contains('(+2)'));
    plugin.overlay!.handleEvent(ControlKey(ControlCode.enter));
    expect(visible(), contains('· test'));
    plugin.store.update(loop, [const PlanEntryItem('finished', state: 'done')]);
    plugin.repaintConsole();
    expect(visible(), contains('plan · 1/1'));
    plugin.overlay!.toggle();
    expect(plugin.overlay!.regionVisible, false);
    plugin.overlay!.toggle();
    expect(plugin.overlay!.regionVisible, true);
    active = false;
    plugin.repaintConsole();
    expect(plugin.overlay!.regionVisible, false);
    active = true;
    plugin.repaintConsole();
    expect(plugin.overlay!.regionVisible, true);
    plugin.store.update(loop, []);
    plugin.repaintConsole();
    expect(visible(), isNot(contains('plan ·')));
    plugin.detachConsole();
    expect(plugin.overlay, isNull);
  });
  test('panel shrinks to the active step on a small terminal', () {
    plugin.store.update(loop, [
      for (var i = 0; i < 20; i++)
        PlanEntryItem('step $i', state: i == 5 ? 'in_progress' : 'pending'),
    ]);
    screen.resize(ScreenLayout.fromSize(40, 8, split: false));
    plugin.repaintConsole();
    expect(visible(), contains('step 5'));
    expect(plugin.overlay!.bounds.height,
        lessThanOrEqualTo(screen.chat.bounds.height));
    screen.resize(ScreenLayout.fromSize(10, 3, split: false));
    plugin.repaintConsole();
    expect(plugin.overlay!.regionVisible, false);
  });

  test('live updates yield to an input-owning modal then restore the plan',
      () async {
    plugin.store
        .update(loop, [const PlanEntryItem('working', state: 'in_progress')]);
    plugin.repaintConsole();
    final key = editor.readKey();
    final modal = OverlayRegion(screen, plugin.overlay!.bounds);
    modal.show(['APPROVAL QUESTION']);
    plugin.store.update(loop, [const PlanEntryItem('finished', state: 'done')]);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(visible(), contains('APPROVAL QUESTION'));
    io.feed('\r');
    await key;
    modal.dispose();
    plugin.repaintConsole();
    expect(visible(), contains('plan · 1/1'));
  });
  test('renderer counts child progress and fits wide characters', () {
    final rows = renderPlanOverlayLines(
        plan: PlanState(items: const [
          PlanEntryItem('長い計画', state: 'in_progress', children: [
            PlanEntryItem('完了', state: 'done'),
          ])
        ]),
        ui: const PlanOverlayUi(),
        width: 24,
        paint: (text, _) => text);
    expect(rows.first, contains('1/2'));
    for (final row in rows) expect(visibleWidth(row), lessThanOrEqualTo(24));
  });
}
