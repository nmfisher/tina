import 'package:test/test.dart';
import 'package:tina/tui/conversation_sidebar.dart';
import 'package:tina_console/tina_console.dart';

import '../helpers/fake_stdio.dart';

void main() {
  late FakeStdio io;
  late Screen screen;
  late ConversationSidebar sidebar;
  setUp(() {
    io = FakeStdio();
    screen = Screen(
      io: io,
      ansi: AnsiCapable.yes,
      layout: ScreenLayout.fromSize(100, 12, sidebarWidth: 24, split: false),
    );
    sidebar = ConversationSidebar(screen);
    sidebar.update([
      (id: 'main', label: 'main', depth: 0),
      (id: 'child', label: 'scout', depth: 1),
      (id: 'nested', label: 'worker', depth: 2),
    ], activeId: 'main');
  });
  tearDown(() {
    sidebar.dispose();
    screen.dispose();
  });

  test('shows nesting and keeps the active row marked when blurred', () {
    io.written.clear();
    sidebar.focus();
    sidebar.blur();
    final out = io.written.toString();
    expect(out, contains('▸ main'));
    expect(out, contains('    scout'));
    expect(out, contains('      worker'));
    expect(out, contains('\x1b[7m'));
  });

  test('arrows select without leaving the sidebar; Enter enters the view', () {
    final selected = <String>[];
    final entered = <String>[];
    sidebar.onSelect = selected.add;
    sidebar.onEnter = entered.add;
    sidebar.focus();
    sidebar.handleEvent(ArrowKey(ArrowDirection.down));
    sidebar.handleEvent(ArrowKey(ArrowDirection.down));
    sidebar.handleEvent(ArrowKey(ArrowDirection.up));
    expect(selected, ['child', 'nested', 'child']);
    expect(sidebar.hasFocus, isTrue);
    expect(sidebar.activeId, 'child');
    expect(entered, isEmpty);
    sidebar.handleEvent(ControlKey(ControlCode.enter));
    expect(entered, ['child']);
    expect(sidebar.handleEvent(PasteInput('do not type')), isTrue);
  });

  test('Ctrl+G and a left arrow can select the sidebar from the view', () {
    final view = PanelFrame(
      screen: screen,
      label: 'main',
      conversationId: 'main',
    );
    view.setOuter(Rect(row: 0, col: 24, width: 76, height: 11));
    final focus = FocusManager()
      ..register(view)
      ..register(sidebar)
      ..home = view;
    focus.handleEvent(ControlKey(ControlCode.ctrlG));
    focus.handleEvent(ArrowKey(ArrowDirection.left));
    expect(focus.highlighted, same(sidebar));
    focus.handleEvent(ControlKey(ControlCode.enter));
    expect(focus.focused, same(sidebar));
    sidebar.onEnter = (_) => focus.focusPanel(view);
    sidebar.handleEvent(ControlKey(ControlCode.enter));
    expect(focus.focused, same(view));
    view.dispose();
  });

  test('scrolls to active entries beyond the first viewport', () {
    sidebar.update([
      for (var i = 0; i < 40; i++) (id: '$i', label: 'agent-$i', depth: 1),
    ], activeId: '0');
    sidebar.focus();
    for (var i = 0; i < 39; i++)
      sidebar.handleEvent(ArrowKey(ArrowDirection.down));
    io.written.clear();
    sidebar.render();
    expect(io.written.toString(), contains('agent-39'));
    expect(io.written.toString(), isNot(contains('agent-0 ')));
    sidebar.handleEvent(ArrowKey(ArrowDirection.down));
    expect(sidebar.activeId, '39');
    sidebar.update([(id: 'main', label: 'main', depth: 0)], activeId: 'main');
    expect(sidebar.activeId, 'main');
  });

  test(
    'sidebar navigation works during a turn and a global approval',
    () async {
      final editor = LineEditor(screen: screen);
      final view = PanelFrame(
        screen: screen,
        label: 'main',
        conversationId: 'main',
      );
      view.setOuter(const Rect(row: 0, col: 24, width: 76, height: 11));
      final focus = FocusManager()
        ..register(view)
        ..register(sidebar)
        ..home = view;
      editor.focusManager = focus;
      var cancelled = false;
      editor.beginCancelMonitor(() => cancelled = true);
      await Future<void>.delayed(Duration.zero);
      io.feedBytes([0x07, 0x1b, 0x5b, 0x44, 0x0d]); // Ctrl+G, left, Enter
      await Future<void>.delayed(Duration.zero);
      expect(focus.focused, same(sidebar));
      io.feedBytes([0x1b, 0x5b, 0x42]); // down
      await Future<void>.delayed(Duration.zero);
      expect(sidebar.activeId, 'child');
      expect(cancelled, isFalse);
      editor.endCancelMonitor();

      var answered = false;
      final approval = editor.readKey(globalKeys: true).then((event) {
        answered = true;
        return event;
      });
      await Future<void>.delayed(Duration.zero);
      io.feedBytes([0x1b, 0x5b, 0x42]);
      await Future<void>.delayed(Duration.zero);
      expect(sidebar.activeId, 'nested');
      expect(
        answered,
        isFalse,
        reason: 'navigation must not answer the approval',
      );
      io.feedBytes([0x79]);
      expect(await approval, CharInput('y'));
      expect(focus.focused, same(sidebar));
      editor.close();
      view.dispose();
    },
  );

  test(
    'sidebar leaves transcript space and the status strip outside panels',
    () {
      for (final width in [1, 20, 30, 60, 80, 120, 200]) {
        final layout = ScreenLayout.fromSize(
          width,
          24,
          sidebarWidth: 24,
          split: false,
        );
        expect(layout.chatLeftCol, layout.sidebar.width);
        expect(layout.chatRightCol, width - 1);
        if (!layout.sidebar.isEmpty) {
          expect(layout.sidebar.width, lessThanOrEqualTo(24));
          expect(layout.chat.width, greaterThanOrEqualTo(18));
          expect(layout.stripRow, greaterThan(layout.bottomBorderRow));
        }
      }
    },
  );
}
