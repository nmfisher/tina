import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_plans/tina_plans.dart';
import 'package:tina_plans_tui/tina_plans_tui.dart';
import 'support/console_fixture.dart';

void main() {
  late Io io;
  late Screen screen;
  late LineEditor editor;
  late PlansPlugin plugin;
  late PlansView view;
  late ConsoleAttachment attachment;
  late AgentLoop loop;
  late bool active;
  late FocusManager focus;
  late PanelFrame chatPanel;
  String visible() {
    final vt = VirtualTerminal(
      width: screen.layout.width,
      height: screen.layout.height,
    )..feed(io.output.toString());
    return List.generate(screen.layout.height, vt.rowText).join('\n');
  }

  void focusPlan() {
    editor.inject(ControlKey(ControlCode.ctrlG));
    editor.inject(ControlKey(ControlCode.tab));
    expect(focus.highlighted, same(view.overlay));
    editor.inject(ControlKey(ControlCode.enter));
    expect(focus.focused, same(view.overlay));
  }

  setUp(() {
    active = true;
    io = Io();
    screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(80, 24, split: false),
    );
    editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
    focus = FocusManager();
    chatPanel = PanelFrame(
      screen: screen,
      label: 'chat',
      conversationId: 'test',
      border: false,
    )..setOuter(screen.chat.bounds);
    focus.register(chatPanel);
    focus.home = chatPanel;
    editor.focusManager = focus;
    plugin = PlansPlugin();
    loop = AgentLoop(provider: ScriptedProvider([]), plugins: [plugin]);
    plugin.mountOn(loop);
    view = PlansView(plugin.observation);
    attachment = ConsoleAttachment.attach(
      view,
      ConsoleContext(screen: screen, editor: editor).forView(
        chat: screen.chat,
        isActive: () => active,
        activate: () {},
        panels: Panels(),
      ),
    );
  });
  tearDown(() {
    attachment.dispose();
    plugin.closeSession();
    chatPanel.dispose();
    editor.close(reportLatency: false);
    screen.dispose();
    unawaited(io.input.close());
  });

  test('plan status follows progress and approval without chat', () async {
    String status() => (VirtualTerminal(
          width: screen.layout.width,
          height: screen.layout.height,
        )..feed(io.output.toString()))
            .rowText(screen.layout.stripRow);
    plugin.store.update(
        loop,
        const [
          PlanEntryItem('Build', state: 'in_progress'),
          PlanEntryItem('Inspect', state: 'done'),
        ],
        approval: PlanApproval.requested);
    await pumpEventQueue();
    expect(status(), contains('plan: Build · 1/2 done · needs approval'));
    view.overlay!.toggle();
    expect(view.overlay!.regionVisible, isFalse);
    expect(status(), contains('needs approval'));
    plugin.store.approve(loop);
    await pumpEventQueue();
    expect(status(), contains('plan: Build · 1/2 done'));
    expect(status(), isNot(contains('needs approval')));
    plugin.store.update(loop, const [
      PlanEntryItem('Build', state: 'done'),
      PlanEntryItem('Inspect', state: 'done'),
    ]);
    await pumpEventQueue();
    expect(status(), contains('plan: 2/2 done'));
    plugin.store.update(loop, const []);
    await pumpEventQueue();
    expect(status(), isNot(contains('plan:')));
  });

  test('detaching plans releases its status while preserving other sources',
      () async {
    final context = ConsoleContext(screen: screen, editor: editor);
    attachment.dispose();
    final releaseOther = context.bindStatus(() => [
          RenderLine(runs: [RenderRun('other feature', null)])
        ]);
    addTearDown(releaseOther);
    attachment = ConsoleAttachment.attach(view, context);
    plugin.store.update(loop, const [PlanEntryItem('Build', state: 'pending')]);
    await pumpEventQueue();
    expect(visible(), contains('plan: 0/1 done'));
    expect(visible(), contains('other feature'));
    attachment.dispose();
    expect(visible(), isNot(contains('plan:')));
    expect(visible(), contains('other feature'));
  });

  test(
    'two views share progress but own focus, selection and expansion',
    () async {
      plugin.store.update(
          loop,
          const [
            PlanEntryItem(
              'parent',
              state: 'pending',
              summary: 'PARENT_DETAIL',
              children: [PlanEntryItem('child', state: 'pending')],
            ),
            PlanEntryItem('next', state: 'pending'),
          ],
          approval: PlanApproval.requested);
      await pumpEventQueue();
      final other = _PlansPresentation(plugin.observation);
      addTearDown(other.dispose);
      expect(other.visible(), contains('parent'));
      expect(other.visible(), contains('(+1)'));
      expect(other.view.overlay, isNot(same(view.overlay)));
      final entries = loop.log.length;

      final prompt = editor.readLine('model > ');
      await pumpEventQueue();
      focusPlan();
      editor.inject(ArrowKey(ArrowDirection.right));
      editor.inject(ArrowKey(ArrowDirection.down));
      expect(view.overlay!.selectedItem!.text, 'child');
      expect(visible(), contains('PARENT_DETAIL'));
      expect(other.visible(), isNot(contains('PARENT_DETAIL')));
      expect(other.view.overlay!.selectedItem, isNull);
      expect(other.focus.focused, same(other.home));

      plugin.store.update(loop, const [
        PlanEntryItem(
          'parent',
          state: 'pending',
          summary: 'PARENT_DETAIL',
          children: [PlanEntryItem('child', state: 'done')],
        ),
        PlanEntryItem('next', state: 'in_progress'),
      ]);
      await pumpEventQueue();
      expect(visible(), contains('plan · 1/3'));
      expect(other.visible(), contains('plan · 1/3'));
      expect(view.overlay!.selectedItem!.text, 'child');
      expect(visible(), contains('PARENT_DETAIL'));
      expect(other.visible(), contains('(+1)'));
      expect(plugin.observation.state.approval, PlanApproval.requested);
      expect(loop.log.length, entries + 1);

      editor.inject(EscapeKey());
      editor.inject(ControlKey(ControlCode.enter));
      await prompt;
    },
  );

  test(
    'scrolling one plans view leaves the other viewport unchanged',
    () async {
      plugin.store.update(loop, [
        for (var i = 0; i < 20; i++)
          PlanEntryItem(
            'step ${i.toString().padLeft(2, '0')}',
            state: 'pending',
          ),
      ]);
      await pumpEventQueue();
      final other = _PlansPresentation(plugin.observation);
      addTearDown(other.dispose);
      screen.resize(ScreenLayout.fromSize(40, 8, split: false));
      chatPanel.setOuter(screen.chat.bounds);
      other.screen.resize(ScreenLayout.fromSize(40, 8, split: false));
      other.home.setOuter(other.screen.chat.bounds);
      io.output.clear();
      other.io.output.clear();
      view.overlay!.focus();
      other.view.overlay!.focus();
      expect(visible(), contains('step 00'));
      final before = other.visible();
      final entries = loop.log.length;
      view.overlay!.handleEvent(ArrowKey(ArrowDirection.pageDown));
      expect(visible(), isNot(contains('step 00')));
      expect(other.visible(), before);
      expect(loop.log.length, entries);
    },
  );

  for (final detachFirst in [true, false]) {
    test('either view detaches independently (first: $detachFirst)', () async {
      final other = _PlansPresentation(plugin.observation);
      addTearDown(other.dispose);
      final retired = detachFirst ? view : other.view;
      final retiredAttachment = detachFirst ? attachment : other.attachment;
      final survivor = detachFirst ? other.view : view;
      final survivorEditor = detachFirst ? other.editor : editor;
      final retiredIo = detachFirst ? io : other.io;
      String survivorVisible() => detachFirst ? other.visible() : visible();
      plugin.store.update(loop, const [
        PlanEntryItem('queued before detach', state: 'pending'),
      ]);
      retiredAttachment.dispose();
      retiredAttachment.dispose();
      retiredIo.output.clear();
      await pumpEventQueue();
      expect(retired.overlay, isNull);
      expect(
        retiredIo.output.toString(),
        isEmpty,
        reason: 'queued refreshes must not repaint a detached view',
      );
      expect(survivorVisible(), contains('queued before detach'));

      final before = loop.log.length;
      final result = await plugin.execute({
        'items': [
          {'text': 'updated while detached', 'state': 'done'},
        ],
      });
      expect(result.isError, isFalse);
      await pumpEventQueue();
      expect(survivorVisible(), contains('updated while detached'));
      expect(loop.log.length, before + 1);

      final prompt = survivorEditor.readLine('model > ');
      await pumpEventQueue();
      survivorEditor.inject(ControlKey(ControlCode.ctrlP));
      expect(survivor.overlay!.regionVisible, isFalse);
      survivorEditor.inject(ControlKey(ControlCode.ctrlP));
      expect(survivor.overlay!.regionVisible, isTrue);
      survivorEditor.inject(ControlKey(ControlCode.enter));
      await prompt;
      expect(loop.log.length, before + 1);

      final replacement = _PlansPresentation(plugin.observation);
      addTearDown(replacement.dispose);
      expect(replacement.visible(), contains('updated while detached'));
      expect(replacement.view.overlay!.regionVisible, isTrue);
      expect(replacement.view.overlay!.selectedItem, isNull);
    });
  }
  test('live progress, child folding, visibility, clear and detach', () async {
    plugin.store.update(loop, [
      const PlanEntryItem(
        'implement',
        state: 'in_progress',
        children: [
          PlanEntryItem('read', state: 'done'),
          PlanEntryItem('test', state: 'pending'),
        ],
      ),
    ]);
    view.repaintConsole();
    expect(visible(), contains('plan · 1/3'));
    expect(visible(), isNot(contains('approve')));
    expect(visible(), isNot(contains('reject')));
    expect(visible(), contains('(+2)'));
    view.overlay!.focus();
    view.overlay!.handleEvent(ControlKey(ControlCode.enter));
    expect(visible(), contains('· test'));
    expect(visible(), isNot(contains('A approve')));
    view.overlay!.handleEvent(ControlKey(ControlCode.enter));
    expect(visible(), contains('(+2)'));
    plugin.store.update(loop, [const PlanEntryItem('finished', state: 'done')]);
    view.repaintConsole();
    expect(visible(), contains('plan · 1/1'));
    view.overlay!.toggle();
    expect(view.overlay!.regionVisible, false);
    view.overlay!.toggle();
    expect(view.overlay!.regionVisible, true);
    active = false;
    view.repaintConsole();
    expect(view.overlay!.regionVisible, false);
    active = true;
    view.repaintConsole();
    expect(view.overlay!.regionVisible, true);
    plugin.store.update(loop, []);
    view.repaintConsole();
    expect(visible(), isNot(contains('plan ·')));
    attachment.dispose();
    expect(view.overlay, isNull);
  });
  test('panel shrinks to the active step on a small terminal', () {
    plugin.store.update(loop, [
      for (var i = 0; i < 20; i++)
        PlanEntryItem('step $i', state: i == 5 ? 'in_progress' : 'pending'),
    ]);
    screen.resize(ScreenLayout.fromSize(40, 8, split: false));
    chatPanel.setOuter(screen.chat.bounds);
    io.output.clear();
    view.repaintConsole();
    expect(visible(), contains('step 5'));
    expect(
      view.overlay!.bounds.height,
      lessThanOrEqualTo(screen.chat.bounds.height),
    );
    screen.resize(ScreenLayout.fromSize(10, 3, split: false));
    chatPanel.setOuter(screen.chat.bounds);
    io.output.clear();
    view.repaintConsole();
    expect(view.overlay!.regionVisible, false);
  });

  test('a visible idle plan does not redraw on the animation timer', () async {
    plugin.store.update(loop, [
      const PlanEntryItem('finished and selectable', state: 'done'),
    ]);
    await pumpEventQueue();
    io.output.clear();
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(
      io.output.toString(),
      isEmpty,
      reason: 'a completed plan must stay selectable while the app is idle',
    );
    screen.resize(ScreenLayout.fromSize(70, 20, split: false));
    chatPanel.setOuter(screen.chat.bounds);
    io.output.clear();
    view.repaintConsole();
    expect(
      io.output.toString(),
      contains('finished and selectable'),
      reason: 'real resize damage still needs a plan repaint',
    );
  });

  test(
    'live updates yield to an input-owning modal then restore the plan',
    () async {
      plugin.store.update(loop, [
        const PlanEntryItem('working', state: 'in_progress'),
      ]);
      view.repaintConsole();
      final key = editor.readKey();
      final modal = OverlayRegion(screen, view.overlay!.bounds);
      modal.show(['APPROVAL QUESTION']);
      plugin.store.update(loop, [
        const PlanEntryItem('finished', state: 'done'),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(visible(), contains('APPROVAL QUESTION'));
      io.feed('\r');
      await key;
      modal.dispose();
      view.repaintConsole();
      expect(visible(), contains('plan · 1/1'));
    },
  );
  test('renderer counts child progress and fits wide characters', () {
    final rows = renderPlanOverlayLines(
      plan: PlanState(
        items: const [
          PlanEntryItem(
            '長い計画',
            state: 'in_progress',
            children: [PlanEntryItem('完了', state: 'done')],
          ),
        ],
      ),
      ui: const PlanOverlayUi(),
      width: 24,
      paint: (text, _) => text,
    );
    expect(rows.first, contains('1/2'));
    for (final row in rows) expect(visibleWidth(row), lessThanOrEqualTo(24));
  });

  test('folded child counts remain visible beside long titles', () {
    final rows = renderPlanOverlayLines(
      plan: PlanState(
        items: const [
          PlanEntryItem(
            'A long parent title that requires clipping',
            state: 'pending',
            children: [
              PlanEntryItem('first', state: 'pending'),
              PlanEntryItem('second', state: 'pending'),
            ],
          ),
        ],
      ),
      ui: const PlanOverlayUi(collapsedRoots: {0}),
      width: 24,
      paint: (text, _) => text,
    );
    expect(rows[1], contains('(+2)'));
    for (final row in rows) expect(visibleWidth(row), lessThanOrEqualTo(24));
  });

  test(
    'real editor routes selection and leaf expansion without submitting or approving',
    () async {
      const long =
          'Read the entire long plan item, including this final detail END_OF_ITEM';
      plugin.store.update(loop, const [
        PlanEntryItem('first', state: 'pending'),
        PlanEntryItem('Inspect behavior', state: 'pending', summary: long),
      ]);
      view.repaintConsole();
      final prompt = editor.readLine('model > ');
      await pumpEventQueue();
      editor.inject(CharInput('my draft'));
      final entries = loop.log.length;
      focusPlan();
      editor.inject(ArrowKey(ArrowDirection.down));
      expect(view.overlay!.selectedItem!.text, 'Inspect behavior');
      expect(visible(), isNot(contains('END_OF_ITEM')));
      editor.inject(ArrowKey(ArrowDirection.right));
      expect(visible(), contains('END_OF_ITEM'));
      editor.inject(ArrowKey(ArrowDirection.right));
      expect(
        visible(),
        contains('END_OF_ITEM'),
        reason: 'Right expands rather than toggles',
      );
      editor.inject(ArrowKey(ArrowDirection.left));
      expect(visible(), isNot(contains('END_OF_ITEM')));
      editor.inject(ControlKey(ControlCode.enter));
      expect(visible(), contains('END_OF_ITEM'));
      expect(loop.log.length, entries);
      expect(plugin.store.state.approval, PlanApproval.none);
      editor.inject(CharInput('z'));
      editor.inject(CharInput('a'));
      editor.inject(CharInput('r'));
      expect(
        loop.log.length,
        entries,
        reason: 'letter keys cannot approve or reject',
      );
      expect(editor.editState.buffer, 'my draft');
      editor.inject(EscapeKey());
      expect(focus.focused, same(chatPanel));
      editor.inject(ControlKey(ControlCode.enter));
      expect(await prompt, 'my draft');
    },
  );

  test(
    'selection and expansion survive live progress changes and reordering',
    () async {
      const long =
          'A selected item with enough text to wrap and end in RETAINED_DETAIL';
      plugin.store.update(loop, const [
        PlanEntryItem('first', state: 'pending'),
        PlanEntryItem('Selected step', state: 'pending', summary: long),
      ]);
      view.repaintConsole();
      final prompt = editor.readLine('model > ');
      await pumpEventQueue();
      focusPlan();
      editor.inject(ArrowKey(ArrowDirection.down));
      editor.inject(ControlKey(ControlCode.enter));
      plugin.store.update(loop, const [
        PlanEntryItem('inserted', state: 'pending'),
        PlanEntryItem('first', state: 'done'),
        PlanEntryItem(
          'Selected step',
          state: 'in_progress',
          summary: '$long UPDATED_SUMMARY',
        ),
      ]);
      view.repaintConsole();
      expect(view.overlay!.selectedItem!.text, 'Selected step');
      expect(visible(), contains('RETAINED_DETAIL'));
      expect(visible(), contains('UPDATED_SUMMARY'));
      editor.inject(EscapeKey());
      editor.inject(ControlKey(ControlCode.enter));
      await prompt;
    },
  );

  test('small focused panels scroll the full plan and expanded text', () async {
    plugin.store.update(loop, [
      for (var i = 0; i < 20; i++)
        PlanEntryItem(
          'step $i',
          summary:
              'This step has long details to read after expanding it END_STEP_$i',
          state: i == 5 ? 'in_progress' : 'pending',
        ),
    ]);
    screen.resize(ScreenLayout.fromSize(40, 8, split: false));
    chatPanel.setOuter(screen.chat.bounds);
    io.output.clear();
    view.repaintConsole();
    final prompt = editor.readLine('model > ');
    await pumpEventQueue();
    focusPlan();
    for (var i = 0; i < 19; i++) editor.inject(ArrowKey(ArrowDirection.down));
    expect(view.overlay!.selectedItem!.text, contains('step 19'));
    expect(visible(), contains('❯'));
    editor.inject(ControlKey(ControlCode.enter));
    for (var i = 0; i < 10; i++)
      editor.inject(ArrowKey(ArrowDirection.pageDown));
    expect(visible(), contains('END_STEP_19'));
    expect(
      view.overlay!.bounds.height,
      lessThanOrEqualTo(screen.chat.bounds.height),
    );
    screen.resize(ScreenLayout.fromSize(80, 24, split: false));
    chatPanel.setOuter(screen.chat.bounds);
    io.output.clear();
    view.repaintConsole();
    expect(view.overlay!.selectedItem!.text, contains('step 19'));
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
            PlanEntryItem(
              'Parent',
              state: 'pending',
              summary: 'Explain the parent work.',
              children: [
                PlanEntryItem(
                  'Child',
                  state: 'pending',
                  summary: 'Explain the child work.',
                ),
              ],
            ),
          ],
          approval: PlanApproval.requested);
      view.repaintConsole();
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
      expect(view.overlay!.selectedItem!.text, 'Child');
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
    },
  );

  test(
    'summaries are hidden when folded, wrap safely and old items still expand',
    () {
      final plan = PlanState(
        items: const [
          PlanEntryItem(
            'Title',
            state: 'pending',
            summary:
                'Summary first line\nSecond paragraph 長い explanation\x1b[2J END_SUMMARY',
          ),
        ],
      );
      List<String> render(PlanState plan, PlanOverlayUi ui) =>
          renderPlanOverlayLines(
            plan: plan,
            ui: ui,
            width: 28,
            paint: (text, _) => text,
          );
      expect(
        render(plan, const PlanOverlayUi()).join('\n'),
        isNot(contains('Summary')),
      );
      final expanded = render(
        plan,
        const PlanOverlayUi(expandedItems: {(0, null)}, focused: true),
      );
      expect(expanded.join('\n'), contains('Summary first line'));
      expect(expanded.join('\n'), contains('END_SUMMARY'));
      expect(expanded.join('\n'), isNot(contains('\x1b')));
      for (final line in expanded)
        expect(visibleWidth(line), lessThanOrEqualTo(28));
      final old = render(
        PlanState(
          items: const [
            PlanEntryItem(
              'An old detailed title that wraps OLD_DETAIL_END',
              state: 'pending',
            ),
          ],
        ),
        const PlanOverlayUi(expandedItems: {(0, null)}),
      );
      expect(old.join('\n'), contains('OLD_DETAIL_END'));
    },
  );

  test(
    'busy input capture still routes plan keys and preserves queued draft',
    () async {
      plugin.store.update(loop, const [
        PlanEntryItem('one', state: 'pending'),
        PlanEntryItem('two', state: 'pending'),
      ]);
      view.repaintConsole();
      final prompt = editor.readLine('model > ');
      await pumpEventQueue();
      final submitted = <String>[];
      editor.beginCancelMonitor(
        () => fail('browsing must not cancel'),
        onQueueSubmit: submitted.add,
      );
      editor.inject(CharInput('queued draft'));
      focusPlan();
      editor.inject(ArrowKey(ArrowDirection.down));
      editor.inject(ControlKey(ControlCode.enter));
      expect(view.overlay!.selectedItem!.text, 'two');
      expect(submitted, isEmpty);
      editor.inject(EscapeKey());
      editor.inject(ControlKey(ControlCode.enter));
      expect(submitted, ['queued draft']);
      editor.endCancelMonitor();
      editor.inject(ControlKey(ControlCode.enter));
      await prompt;
    },
  );

  test(
    'hiding or unloading the focused plan returns focus to the draft',
    () async {
      plugin.store.update(loop, const [PlanEntryItem('one', state: 'pending')]);
      view.repaintConsole();
      final prompt = editor.readLine('model > ');
      await pumpEventQueue();
      editor.inject(CharInput('draft'));
      focusPlan();
      editor.inject(ControlKey(ControlCode.ctrlP));
      expect(focus.focused, same(chatPanel));
      expect(view.overlay!.regionVisible, isFalse);
      editor.inject(ControlKey(ControlCode.ctrlP));
      focusPlan();
      attachment.dispose();
      expect(focus.focused, same(chatPanel));
      editor.inject(ControlKey(ControlCode.enter));
      expect(await prompt, 'draft');
    },
  );
}

final class _PlansPresentation {
  _PlansPresentation(PlanObservation plans) {
    home.setOuter(screen.chat.bounds);
    focus.register(home);
    focus.home = home;
    editor.focusManager = focus;
    view = PlansView(plans);
    attachment = ConsoleAttachment.attach(
      view,
      ConsoleContext(screen: screen, editor: editor).forView(
        chat: screen.chat,
        isActive: () => true,
        activate: () {},
        panels: Panels(),
      ),
    );
  }

  final io = Io();
  late final screen = Screen(
    io: io,
    layout: ScreenLayout.fromSize(80, 24, split: false),
  );
  late final editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
  final focus = FocusManager();
  late final home = PanelFrame(
    screen: screen,
    label: 'chat',
    conversationId: 'other',
    border: false,
  );
  late final PlansView view;
  late final ConsoleAttachment attachment;

  String visible() {
    final terminal = VirtualTerminal(
      width: screen.layout.width,
      height: screen.layout.height,
    )..feed(io.output.toString());
    return List.generate(screen.layout.height, terminal.rowText).join('\n');
  }

  void dispose() {
    attachment.dispose();
    home.dispose();
    editor.close(reportLatency: false);
    screen.dispose();
    unawaited(io.input.close());
  }
}
