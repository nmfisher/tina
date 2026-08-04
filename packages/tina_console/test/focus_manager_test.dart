import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

/// A [Focusable] that records focus/highlight transitions and bounds, for
/// driving the [FocusManager] state machine without a real terminal.
class _Fake implements Focusable {
  final String name;
  _Fake(this.name, {Rect? bounds, this.canFocusFlag = true})
      : boundsRect = bounds ?? Rect.empty;

  final bool canFocusFlag;
  final Rect boundsRect;
  bool isFocused = false;
  bool isHighlighted = false;
  int focusCount = 0;
  int blurCount = 0;
  int highlightCount = 0;
  int unhighlightCount = 0;

  @override
  bool get hasFocus => isFocused;

  @override
  bool get canFocus => canFocusFlag;

  @override
  Rect get bounds => boundsRect;

  @override
  void focus() {
    isFocused = true;
    // Mirrors ConversationPanel.focus: gaining focus clears any cycling
    // highlight so the panel goes yellow -> cyan with no plain frame between.
    isHighlighted = false;
    focusCount++;
  }

  @override
  void blur() {
    isFocused = false;
    blurCount++;
  }

  @override
  void highlight() {
    isHighlighted = true;
    highlightCount++;
  }

  @override
  void unhighlight() {
    isHighlighted = false;
    unhighlightCount++;
  }

  @override
  bool handleEvent(InputEvent event) => false;
}

void main() {
  late _Fake chat, menu, info;
  late FocusManager fm;

  setUp(() {
    chat = _Fake('chat', bounds: const Rect(row: 3, col: 0, width: 60, height: 18));
    menu = _Fake('menu', bounds: const Rect(row: 0, col: 0, width: 100, height: 3));
    info = _Fake('info', bounds: const Rect(row: 3, col: 65, width: 33, height: 18));
    fm = FocusManager()
      ..register(chat)
      ..register(menu)
      ..register(info)
      ..home = chat; // chat is the focused panel at start
  });

  group('initial state', () {
    test('home is focused; nothing highlighted; not cycling', () {
      expect(fm.focused, same(chat));
      expect(fm.highlighted, isNull);
      expect(fm.isCycling, isFalse);
      expect(chat.isFocused, isTrue);
    });
  });

  group('engage / cycling', () {
    test('engage highlights the current focus (it turns yellow)', () {
      fm.engage(); // chat is the focus -> chat turns yellow
      expect(fm.isCycling, isTrue);
      expect(fm.highlighted, same(chat));
      expect(chat.isHighlighted, isTrue);
      expect(fm.focused, same(chat)); // focus unchanged
    });

    test('Tab moves the highlight forward through all panels', () {
      fm.engage(); // chat
      fm.moveHighlightCyclic(1); // -> menu
      expect(fm.highlighted, same(menu));
      fm.moveHighlightCyclic(1); // -> info
      expect(fm.highlighted, same(info));
      fm.moveHighlightCyclic(1); // wraps -> chat
      expect(fm.highlighted, same(chat));
    });

    test('arrows move the highlight spatially from the focus', () {
      fm.engage(); // chat highlighted
      fm.moveHighlightDirection(ArrowDirection.up); // above chat -> menu
      expect(fm.highlighted, same(menu));
    });

    test('a highlighted panel can also be the focus (one color via suppression)', () {
      fm.engage(); // chat is highlighted AND focused
      expect(fm.highlighted, same(chat));
      expect(fm.focused, same(chat));
    });
  });

  group('commit / cancel', () {
    test('commit makes the highlighted panel the focus; old focus blurs', () {
      fm.engage(); // chat
      fm.moveHighlightCyclic(1); // -> menu
      fm.commit();
      expect(fm.isCycling, isFalse);
      expect(fm.focused, same(menu));
      expect(fm.highlighted, isNull);
      expect(menu.isFocused, isTrue);
      expect(chat.isFocused, isFalse);
    });

    test('commit focuses the highlighted panel with no intermediate unhighlight', () {
      // Regression: commit used to unhighlight the target before focusing it,
      // painting a plain (unfocused) frame between the yellow highlight and the
      // cyan focus — visible as a yellow -> black -> cyan flash. focus() clears
      // the highlight itself, so the target must go yellow -> cyan directly.
      fm.engage(); // chat highlighted
      fm.moveHighlightCyclic(1); // -> menu highlighted (yellow)
      expect(menu.unhighlightCount, 0);
      fm.commit(); // menu becomes the focus (cyan)
      expect(menu.unhighlightCount, 0,
          reason: 'commit must not unhighlight the target before focusing it');
      expect(menu.focusCount, 1);
      expect(menu.isFocused, isTrue);
      expect(menu.isHighlighted, isFalse, reason: 'focus() clears the highlight');
    });

    test('cancel clears the highlight; focus unchanged', () {
      fm.engage(); // chat highlighted
      fm.cancel();
      expect(fm.isCycling, isFalse);
      expect(fm.highlighted, isNull);
      expect(fm.focused, same(chat));
    });

    test('returnHome restores focus to the home panel', () {
      fm.engage();
      fm.moveHighlightCyclic(1); // menu
      fm.commit(); // menu focused
      expect(fm.focused, same(menu));
      fm.returnHome();
      expect(fm.focused, same(chat));
      expect(chat.isFocused, isTrue);
    });
  });

  group('handleEvent', () {
    test('Ctrl+G engages cycling on the current focus', () {
      expect(fm.handleEvent(ControlKey(ControlCode.ctrlG)), isTrue);
      expect(fm.isCycling, isTrue);
      expect(fm.highlighted, same(chat)); // the focus turns yellow
    });

    test('while cycling, arrows move the highlight (modal)', () {
      fm.handleEvent(ControlKey(ControlCode.ctrlG)); // engage -> chat
      expect(fm.handleEvent(ArrowKey(ArrowDirection.up)), isTrue); // up -> menu
      expect(fm.isCycling, isTrue);
      expect(fm.highlighted, same(menu));
    });

    test('Enter commits the highlighted panel', () {
      fm.handleEvent(ControlKey(ControlCode.ctrlG)); // engage -> chat
      fm.handleEvent(ControlKey(ControlCode.tab)); // -> menu
      expect(fm.handleEvent(ControlKey(ControlCode.enter)), isTrue);
      expect(fm.isCycling, isFalse);
      expect(fm.focused, same(menu));
    });

    test('Esc cancels cycling, keeping the focus', () {
      fm.handleEvent(ControlKey(ControlCode.ctrlG)); // engage
      expect(fm.handleEvent(EscapeKey()), isTrue);
      expect(fm.isCycling, isFalse);
      expect(fm.focused, same(chat));
    });

    test('Esc when not cycling and focus != home returns home', () {
      fm.engage();
      fm.moveHighlightCyclic(1); // menu
      fm.commit(); // menu focused
      expect(fm.handleEvent(EscapeKey()), isTrue);
      expect(fm.focused, same(chat));
    });

    test('Esc at home falls through (editor handles double-Esc)', () {
      expect(fm.handleEvent(EscapeKey()), isFalse);
      expect(fm.focused, same(chat));
    });

    test('non-nav key falls through when not cycling', () {
      expect(fm.handleEvent(CharInput('x')), isFalse);
    });
  });
}
