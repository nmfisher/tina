import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';

import 'stdio_fake.dart';

class _Modal implements ModalSurface {
  _Modal([this.consume = true]);
  @override
  bool isActive = true;

  /// Whether handleEvent consumes (true) or only observes (false).
  bool consume;
  final events = <InputEvent>[];
  @override
  bool handleEvent(InputEvent event) {
    events.add(event);
    return consume;
  }
}

void main() {
  late LineEditor editor;
  late PanelFrame chat;
  late PanelFrame panel;
  late FocusManager focus;
  late List<InputEvent> received;
  var interrupts = 0;

  setUp(() async {
    final screen = Screen(
        io: FakeStdio(),
        layout: ScreenLayout.fromSize(100, 24),
        ansi: AnsiCapable.yes);
    editor = LineEditor(screen: screen);
    received = [];
    interrupts = 0;
    // ignore: deprecated_member_use_from_same_package
    editor.onInterrupt = () {
      interrupts++;
      return true;
    };
    editor.onMaximizeToggle = () => true;
    editor.onRawView = () => true;
    editor.onBackTab = () => true;
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

  test('the armed chat prompt outranks the focused exclusive panel', () {
    // setUp arms readLine and then focuses the exclusive panel — the exact
    // field wedge (2026-09-24): a read-only panel focused from an earlier
    // overlay while the prompt waits. The prompt must stand the panel down;
    // only the wheel stays panel-owned.
    editor.inject(CharInput('ls'));
    expect(editor.editState.buffer, 'draftls',
        reason: 'typed text lands in the armed prompt, not the panel');
    expect(received, isEmpty);

    final wheel = ScrollEvent(up: true);
    editor.inject(wheel);
    expect(received, [same(wheel)],
        reason: 'wheel scroll is panel-owned even under an armed prompt');

    // Every other key class also stays out of the panel while the prompt
    // is armed — including ones the panel used to swallow whole.
    for (final event in <InputEvent>[
      PasteInput('pasted'),
      ArrowKey(ArrowDirection.up),
      EditingKey(EditingAction.delete),
      AltKey(0x64),
      FunctionKey(FunctionKeyCode.f10),
      UnknownEscape([27, 91, 99]),
    ]) {
      editor.inject(event);
    }
    expect(received, [same(wheel)],
        reason: 'not one non-wheel event reached the panel');

    // The quit flow still works under the wedge: ctrl+C arms, then confirms.
    editor.inject(ControlKey(ControlCode.ctrlC));
    expect(interrupts, 0, reason: 'the first ctrl+c only arms the confirm');
    editor.inject(ControlKey(ControlCode.ctrlC));
    expect(interrupts, 0);
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

  test('double Escape leaves an exclusive panel and returns chat input', () {
    editor.inject(ControlKey(ControlCode.ctrlG));
    editor.inject(EscapeKey());
    expect(focus.isCycling, isFalse);
    expect(focus.focused, same(panel));
    final escape = EscapeKey();
    editor.inject(escape);
    expect(received, isEmpty);
    expect(focus.focused, same(chat));
    editor.inject(CharInput('new instruction'));
    expect(editor.editState.buffer, 'new instruction');
  });

  test(
      'queue mode queues chars; ESC reaches an overlay-stood-down panel '
      'and is otherwise the cancel gesture', () {
    var cancelled = 0;
    final submitted = <String>[];
    editor.beginCancelMonitor(() => cancelled++, onQueueSubmit: submitted.add);
    editor.inject(CharInput('command'));
    editor.inject(ControlKey(ControlCode.enter));
    editor.inject(EscapeKey());
    // Pre-fix: the panel route (armed before the monitor in setUp) swallowed
    // all three. The armed prompt now stands the panel down, so queue mode
    // consumes the chars (submit on Enter) and ESC becomes the cancel once
    // the queue buffer is empty.
    expect(received, isEmpty);
    expect(cancelled, 1, reason: 'ESC with an empty queue cancels the turn');
    expect(submitted, ['command']);
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

  test('a declining modal shields the panel from the cancel monitor', () {
    // Field-wedge regression: with the panel route stood down (prompt armed)
    // an overlay's unhandled key must still stop at the overlay — it used to
    // sail into the cancel monitor, which fired a bogus cancel and leaked the
    // key to the focused panel on the way.
    final modal = _Modal(false);
    editor.registerModal(modal);
    editor.beginCancelMonitor(() => fail('background cancellation'));
    final escape = EscapeKey();
    editor.inject(escape);
    editor.inject(CharInput('typed'));
    expect(modal.events, [same(escape), CharInput('typed')],
        reason: 'every key is offered to the overlay while it is active');
    expect(received, isEmpty,
        reason: 'nothing leaks past the overlay to the focused panel');
    expect(editor.editState.buffer, 'draft',
        reason: 'and nothing edits the armed prompt either');
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
    expect(answered, isFalse, reason: 'ctrl+c is the quit flow, not a deny');
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
    // The burst window has expired by now: the overflow chars are stale
    // (tina's stale-burst drop) and must never answer a future readKey —
    // they are dropped, not delivered to the prompt or the panel.
    editor.inject(CharInput('new input'));
    expect(received, isEmpty,
        reason: 'the panel is stood down; nothing may spill into it');
    expect(editor.editState.buffer, 'draftnew input');
  });

  test('an approval-era paste goes to the prompt, never to the panel',
      () async {
    final response = editor.readKey(globalKeys: true);
    await pumpEventQueue();
    editor.inject(PasteInput('pending paste'));
    expect(received, isEmpty);
    editor.inject(CharInput('n'));
    await response;
    await pumpEventQueue();
    expect(received, isEmpty,
        reason: 'the paste typed while the prompt is armed edits the prompt');
    expect(editor.editState.buffer, 'draftpending paste');
  });
}
