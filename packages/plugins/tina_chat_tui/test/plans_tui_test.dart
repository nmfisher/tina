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
  late FocusManager focus;
  late PanelFrame chatPanel;
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
    focus = FocusManager();
    chatPanel = PanelFrame(
        screen: screen, label: 'chat', conversationId: 'test', border: false)
      ..setOuter(screen.chat.bounds);
    focus.register(chatPanel);
    focus.home = chatPanel;
    editor.focusManager = focus;
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
    chatPanel.dispose();
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
    expect(visible(), isNot(contains('approve')));
    expect(visible(), isNot(contains('reject')));
    expect(visible(), contains('(+2)'));
    plugin.overlay!.focus();
    plugin.overlay!.handleEvent(ControlKey(ControlCode.enter));
    expect(visible(), contains('· test'));
    expect(visible(), isNot(contains('A approve')));
    plugin.overlay!.handleEvent(ControlKey(ControlCode.enter));
    expect(visible(), contains('(+2)'));
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
    chatPanel.setOuter(screen.chat.bounds);
    io.output.clear();
    plugin.repaintConsole();
    expect(visible(), contains('step 5'));
    expect(plugin.overlay!.bounds.height,
        lessThanOrEqualTo(screen.chat.bounds.height));
    screen.resize(ScreenLayout.fromSize(10, 3, split: false));
    chatPanel.setOuter(screen.chat.bounds);
    io.output.clear();
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

  test('folded child counts remain visible beside long titles', () {
    final rows = renderPlanOverlayLines(
        plan: PlanState(items: const [
          PlanEntryItem('A long parent title that requires clipping',
              state: 'pending',
              children: [
                PlanEntryItem('first', state: 'pending'),
                PlanEntryItem('second', state: 'pending'),
              ])
        ]),
        ui: const PlanOverlayUi(collapsedRoots: {0}),
        width: 24,
        paint: (text, _) => text);
    expect(rows[1], contains('(+2)'));
    for (final row in rows) expect(visibleWidth(row), lessThanOrEqualTo(24));
  });

  void focusPlan() {
    editor.inject(ControlKey(ControlCode.ctrlG));
    editor.inject(ControlKey(ControlCode.tab));
    expect(focus.highlighted, same(plugin.overlay));
    editor.inject(ControlKey(ControlCode.enter));
    expect(focus.focused, same(plugin.overlay));
  }

  test(
      'real editor routes selection and leaf expansion without submitting or approving',
      () async {
    const long =
        'Read the entire long plan item, including this final detail END_OF_ITEM';
    plugin.store.update(loop, const [
      PlanEntryItem('first', state: 'pending'),
      PlanEntryItem('Inspect behavior', state: 'pending', summary: long)
    ]);
    plugin.repaintConsole();
    final prompt = editor.readLine('model > ');
    await pumpEventQueue();
    editor.inject(CharInput('my draft'));
    final entries = loop.log.length;
    focusPlan();
    editor.inject(ArrowKey(ArrowDirection.down));
    expect(plugin.overlay!.selectedItem!.text, 'Inspect behavior');
    expect(visible(), isNot(contains('END_OF_ITEM')));
    editor.inject(ArrowKey(ArrowDirection.right));
    expect(visible(), contains('END_OF_ITEM'));
    editor.inject(ArrowKey(ArrowDirection.right));
    expect(visible(), contains('END_OF_ITEM'),
        reason: 'Right expands rather than toggles');
    editor.inject(ArrowKey(ArrowDirection.left));
    expect(visible(), isNot(contains('END_OF_ITEM')));
    editor.inject(ControlKey(ControlCode.enter));
    expect(visible(), contains('END_OF_ITEM'));
    expect(loop.log.length, entries);
    expect(plugin.store.state.approval, PlanApproval.none);
    editor.inject(CharInput('z'));
    editor.inject(CharInput('a'));
    editor.inject(CharInput('r'));
    expect(loop.log.length, entries,
        reason: 'letter keys cannot approve or reject');
    expect(editor.editState.buffer, 'my draft');
    editor.inject(EscapeKey());
    expect(focus.focused, same(chatPanel));
    editor.inject(ControlKey(ControlCode.enter));
    expect(await prompt, 'my draft');
  });

  test('selection and expansion survive live progress changes and reordering',
      () async {
    const long =
        'A selected item with enough text to wrap and end in RETAINED_DETAIL';
    plugin.store.update(loop, const [
      PlanEntryItem('first', state: 'pending'),
      PlanEntryItem('Selected step', state: 'pending', summary: long)
    ]);
    plugin.repaintConsole();
    final prompt = editor.readLine('model > ');
    await pumpEventQueue();
    focusPlan();
    editor.inject(ArrowKey(ArrowDirection.down));
    editor.inject(ControlKey(ControlCode.enter));
    plugin.store.update(loop, const [
      PlanEntryItem('inserted', state: 'pending'),
      PlanEntryItem('first', state: 'done'),
      PlanEntryItem('Selected step',
          state: 'in_progress', summary: '$long UPDATED_SUMMARY')
    ]);
    plugin.repaintConsole();
    expect(plugin.overlay!.selectedItem!.text, 'Selected step');
    expect(visible(), contains('RETAINED_DETAIL'));
    expect(visible(), contains('UPDATED_SUMMARY'));
    editor.inject(EscapeKey());
    editor.inject(ControlKey(ControlCode.enter));
    await prompt;
  });

  test('small focused panels scroll the full plan and expanded text', () async {
    plugin.store.update(loop, [
      for (var i = 0; i < 20; i++)
        PlanEntryItem('step $i',
            summary:
                'This step has long details to read after expanding it END_STEP_$i',
            state: i == 5 ? 'in_progress' : 'pending')
    ]);
    screen.resize(ScreenLayout.fromSize(40, 8, split: false));
    chatPanel.setOuter(screen.chat.bounds);
    io.output.clear();
    plugin.repaintConsole();
    final prompt = editor.readLine('model > ');
    await pumpEventQueue();
    focusPlan();
    for (var i = 0; i < 19; i++) editor.inject(ArrowKey(ArrowDirection.down));
    expect(plugin.overlay!.selectedItem!.text, contains('step 19'));
    expect(visible(), contains('❯'));
    editor.inject(ControlKey(ControlCode.enter));
    for (var i = 0; i < 10; i++)
      editor.inject(ArrowKey(ArrowDirection.pageDown));
    expect(visible(), contains('END_STEP_19'));
    expect(plugin.overlay!.bounds.height,
        lessThanOrEqualTo(screen.chat.bounds.height));
    screen.resize(ScreenLayout.fromSize(80, 24, split: false));
    chatPanel.setOuter(screen.chat.bounds);
    io.output.clear();
    plugin.repaintConsole();
    expect(plugin.overlay!.selectedItem!.text, contains('step 19'));
    editor.inject(EscapeKey());
    editor.inject(ControlKey(ControlCode.enter));
    await prompt;
  });

  test(
      'focused plan is a browser for summaries and subtasks, with no mutations',
      () async {
    plugin.store.update(
        loop,
        const [
          PlanEntryItem('Parent',
              state: 'pending',
              summary: 'Explain the parent work.',
              children: [
                PlanEntryItem('Child',
                    state: 'pending', summary: 'Explain the child work.')
              ])
        ],
        approval: PlanApproval.requested);
    plugin.repaintConsole();
    expect(visible(), isNot(contains('Explain the parent')));
    final before = loop.log.length;
    final prompt = editor.readLine('model > ');
    await pumpEventQueue();
    focusPlan();
    expect(visible(), isNot(contains('approve')));
    expect(visible(), isNot(contains('reject')));
    for (final key in ['a', 'A', 'r', 'R']) editor.inject(CharInput(key));
    editor.inject(CharInput(' '));
    expect(visible(), contains('Explain the parent work.'));
    editor.inject(ArrowKey(ArrowDirection.down));
    expect(plugin.overlay!.selectedItem!.text, 'Child');
    expect(visible(), isNot(contains('Explain the child work.')));
    editor.inject(ArrowKey(ArrowDirection.right));
    expect(visible(), contains('Explain the child work.'));
    editor.inject(ArrowKey(ArrowDirection.left));
    expect(visible(), isNot(contains('Explain the child work.')));
    expect(loop.log.length, before);
    expect(plugin.store.state.approval, PlanApproval.requested);
    expect(plugin.store.state.items.single.children.single.state, 'pending');
    editor.inject(EscapeKey());
    editor.inject(ControlKey(ControlCode.enter));
    await prompt;
  });

  test(
      'summaries are hidden when folded, wrap safely and old items still expand',
      () {
    final plan = PlanState(items: const [
      PlanEntryItem('Title',
          state: 'pending',
          summary:
              'Summary first line\nSecond paragraph 長い explanation\x1b[2J END_SUMMARY')
    ]);
    List<String> render(PlanState plan, PlanOverlayUi ui) =>
        renderPlanOverlayLines(
            plan: plan, ui: ui, width: 28, paint: (text, _) => text);
    expect(render(plan, const PlanOverlayUi()).join('\n'),
        isNot(contains('Summary')));
    final expanded = render(
        plan, const PlanOverlayUi(expandedItems: {(0, null)}, focused: true));
    expect(expanded.join('\n'), contains('Summary first line'));
    expect(expanded.join('\n'), contains('END_SUMMARY'));
    expect(expanded.join('\n'), isNot(contains('\x1b')));
    for (final line in expanded)
      expect(visibleWidth(line), lessThanOrEqualTo(28));
    final old = render(
        PlanState(items: const [
          PlanEntryItem('An old detailed title that wraps OLD_DETAIL_END',
              state: 'pending')
        ]),
        const PlanOverlayUi(expandedItems: {(0, null)}));
    expect(old.join('\n'), contains('OLD_DETAIL_END'));
  });

  test('busy input capture still routes plan keys and preserves queued draft',
      () async {
    plugin.store.update(loop, const [
      PlanEntryItem('one', state: 'pending'),
      PlanEntryItem('two', state: 'pending')
    ]);
    plugin.repaintConsole();
    final prompt = editor.readLine('model > ');
    await pumpEventQueue();
    final submitted = <String>[];
    editor.beginCancelMonitor(() => fail('browsing must not cancel'),
        onQueueSubmit: submitted.add);
    editor.inject(CharInput('queued draft'));
    focusPlan();
    editor.inject(ArrowKey(ArrowDirection.down));
    editor.inject(ControlKey(ControlCode.enter));
    expect(plugin.overlay!.selectedItem!.text, 'two');
    expect(submitted, isEmpty);
    editor.inject(EscapeKey());
    editor.inject(ControlKey(ControlCode.enter));
    expect(submitted, ['queued draft']);
    editor.endCancelMonitor();
    editor.inject(ControlKey(ControlCode.enter));
    await prompt;
  });

  test('hiding or unloading the focused plan returns focus to the draft',
      () async {
    plugin.store.update(loop, const [PlanEntryItem('one', state: 'pending')]);
    plugin.repaintConsole();
    final prompt = editor.readLine('model > ');
    await pumpEventQueue();
    editor.inject(CharInput('draft'));
    focusPlan();
    editor.inject(ControlKey(ControlCode.ctrlP));
    expect(focus.focused, same(chatPanel));
    expect(plugin.overlay!.regionVisible, isFalse);
    editor.inject(ControlKey(ControlCode.ctrlP));
    focusPlan();
    plugin.detachConsole();
    expect(focus.focused, same(chatPanel));
    editor.inject(ControlKey(ControlCode.enter));
    expect(await prompt, 'draft');
  });
}
