import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';

import 'stdio_fake.dart';

class _Modal implements ModalSurface {
  @override
  bool isActive = true;
  final events = <InputEvent>[];
  @override
  bool handleEvent(InputEvent event) {
    events.add(event);
    return true;
  }
}

void main() {
  late LineEditor editor;
  late PanelFrame chat;
  late PanelFrame panel;
  late FocusManager focus;
  late List<InputEvent> received;
  var interrupts = 0;
  var shortcuts = 0;

  setUp(() async {
    final screen = Screen(
        io: FakeStdio(),
        layout: ScreenLayout.fromSize(100, 24),
        ansi: AnsiCapable.yes);
    editor = LineEditor(screen: screen);
    received = [];
    interrupts = 0;
    shortcuts = 0;
    // ignore: deprecated_member_use_from_same_package
    editor.onInterrupt = () {
      interrupts++;
      return true;
    };
    editor.onMaximizeToggle = () {
      shortcuts++;
      return true;
    };
    editor.onRawView = () {
      shortcuts++;
      return true;
    };
    editor.onBackTab = () {
      shortcuts++;
      return true;
    };
    chat = PanelFrame(screen: screen, label: 'Chat', conversationId: 'chat');
    panel = PanelFrame(
        screen: screen,
        label: 'Custom',
        conversationId: 'custom',
        inputMode: PanelInputMode.exclusive)
      ..onPanelKey = (event) {
        received.add(event);
        return false;
      };
    chat.setOuter(const Rect(row: 0, col: 0, width: 48, height: 24));
    panel.setOuter(const Rect(row: 0, col: 50, width: 48, height: 24));
    focus = FocusManager()
      ..register(chat)
      ..register(panel)
      ..home = chat;
    editor.focusManager = focus;
    editor.readLine('> ');
    await pumpEventQueue();
    editor.loadEditState('draft', 5);
    focus.focusPanel(panel);
  });

  tearDown(() {
    editor.close();
    panel.dispose();
    chat.dispose();
  });

  test('exclusive input reaches its owner and never edits or cancels chat', () {
    final events = <InputEvent>[
      CharInput('ls'),
      PasteInput('pasted\ntext'),
      ArrowKey(ArrowDirection.up),
      ControlKey(ControlCode.tab),
      ControlKey(ControlCode.enter),
      ControlKey(ControlCode.ctrlC),
      ControlKey(ControlCode.ctrlD),
      EscapeKey(),
      ControlKey(ControlCode.ctrlW),
      ControlKey(ControlCode.ctrlR),
      ControlKey(ControlCode.ctrlO),
      ControlKey(ControlCode.backtab),
      EditingKey(EditingAction.delete),
      AltKey(0x64),
      FunctionKey(FunctionKeyCode.f10),
      UnknownEscape([27, 91, 99]),
    ];
    for (final event in events) {
      editor.inject(event);
    }
    expect(received, orderedEquals(events));
    expect(editor.editState.buffer, 'draft');
    expect(interrupts, 0);
    expect(shortcuts, 0);
    expect(focus.focused, same(panel));
  });

  test('Ctrl+G cycles away; cycling keys never reach the panel', () {
    editor.inject(ControlKey(ControlCode.ctrlG));
    expect(focus.isCycling, isTrue);
    editor.inject(ControlKey(ControlCode.ctrlC));
    editor.inject(ControlKey(ControlCode.tab));
    editor.inject(ControlKey(ControlCode.enter));
    expect(focus.focused, same(chat));
    expect(received, isEmpty);
    editor.inject(CharInput('!'));
    expect(editor.editState.buffer, 'draft!');
    editor.inject(ControlKey(ControlCode.ctrlC));
    editor.inject(ControlKey(ControlCode.ctrlC));
    // Quit confirmed: readLine was armed by setUp, and the quit flow
    // completes it; the panel never saw any of the Ctrl+Cs.
    expect(received, isEmpty);
    expect(interrupts, 0);
  });

  test('Escape cancels cycling, then belongs to the panel again', () {
    editor.inject(ControlKey(ControlCode.ctrlG));
    editor.inject(EscapeKey());
    expect(focus.isCycling, isFalse);
    expect(focus.focused, same(panel));
    final escape = EscapeKey();
    editor.inject(escape);
    expect(received, [escape]);
  });

  test('queue and cancel monitoring do not take input from the panel', () {
    var cancelled = 0;
    final submitted = <String>[];
    editor.beginCancelMonitor(() => cancelled++, onQueueSubmit: submitted.add);
    editor.inject(CharInput('command'));
    editor.inject(ControlKey(ControlCode.enter));
    editor.inject(EscapeKey());
    expect(received, hasLength(3));
    expect(cancelled, 0);
    expect(submitted, isEmpty);
    editor.endCancelMonitor();
  });

  test('local overlays receive keys before the panel', () async {
    final response = editor.readKey();
    await pumpEventQueue();
    editor.inject(ControlKey(ControlCode.ctrlC)); // arms the quit confirm
    var answered = false;
    response.then((_) => answered = true);
    await pumpEventQueue();
    expect(answered, isFalse, reason: 'the first press only arms');
    editor.inject(ControlKey(ControlCode.ctrlC)); // confirms quit
    expect(await response, ControlKey(ControlCode.ctrlC));
    expect(received, isEmpty);
    expect(interrupts, 0);
  });

  test('registered modals receive keys even during cancel monitoring', () {
    final modal = _Modal();
    editor.registerModal(modal);
    editor.beginCancelMonitor(() => fail('background cancellation'));
    // Ctrl+C is intercepted by the quit gate before any consumer — the modal
    // never sees it, and the monitor's cancel never fires on it.
    editor.inject(ControlKey(ControlCode.ctrlC));
    final escape = EscapeKey();
    editor.inject(escape);
    // EscapeKey has no ==: compare identity, not a fresh literal.
    expect(modal.events, [same(escape)]);
    expect(received, isEmpty);
    expect(interrupts, 0);
    editor.endCancelMonitor();
  });

  test('approval answer and navigation keys never reach the panel', () async {
    for (final event in <InputEvent>[
      CharInput('y'),
      ArrowKey(ArrowDirection.up),
      EscapeKey()
    ]) {
      final response = editor.readKey(globalKeys: true);
      await pumpEventQueue();
      editor.inject(event);
      expect(await response, same(event));
    }
    expect(received, isEmpty);
    expect(editor.editState.buffer, 'draft');
  });

  test('approval Ctrl+C arms the quit confirm; it never answers the prompt',
      () async {
    final response = editor.readKey(globalKeys: true);
    await pumpEventQueue();
    editor.inject(ControlKey(ControlCode.ctrlC)); // arm only
    var answered = false;
    response.then((_) => answered = true);
    await pumpEventQueue();
    expect(answered, isFalse,
        reason: 'ctrl+c is the quit flow, not a deny');
    expect(interrupts, 0);
    editor.inject(ControlKey(ControlCode.ctrlC)); // confirm quit
    expect(await response, ControlKey(ControlCode.ctrlC));
    expect(received, isEmpty);
  });

  test('approval character overflow cannot spill into the panel', () async {
    final response = editor.readKey(globalKeys: true);
    await pumpEventQueue();
    editor.inject(CharInput('y'));
    editor.inject(CharInput('unexpected command'));
    await response;
    expect(received, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    editor.inject(CharInput('new input'));
    expect(received, [CharInput('new input')]);
  });

  test('a held approval paste reaches the owner only after approval resolves',
      () async {
    final response = editor.readKey(globalKeys: true);
    await pumpEventQueue();
    editor.inject(PasteInput('pending paste'));
    expect(received, isEmpty);
    editor.inject(CharInput('n'));
    await response;
    await pumpEventQueue();
    expect(received, [PasteInput('pending paste')]);
    expect(editor.editState.buffer, 'draft');
  });
}
