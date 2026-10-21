import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';

void main() {
  group('StatusSelection model', () {
    test('engage highlights the first segment and cycle moves the highlight', () {
      final sel = StatusSelection();
      expect(sel.hasSegments, isFalse);
      sel.register('a', () {});
      sel.register('b', () {});
      expect(sel.hasSegments, isTrue);
      expect(sel.active, isFalse);
      sel.engage();
      expect(sel.active, isTrue);
      expect(sel.isHighlighted('a'), isTrue);
      sel.cycle(1);
      expect(sel.isHighlighted('b'), isTrue);
      expect(sel.isHighlighted('a'), isFalse);
      sel.cycle(-1);
      expect(sel.isHighlighted('a'), isTrue);
    });

    test('engage is a no-op when nothing is registered', () {
      final sel = StatusSelection();
      sel.engage();
      expect(sel.active, isFalse);
      expect(sel.highlightedId, isNull);
    });

    test('activate runs the highlighted segment action and ends cycling', () {
      final sel = StatusSelection();
      String? activated;
      sel.register('a', () => activated = 'a');
      sel.register('b', () => activated = 'b');
      sel.engage();
      sel.cycle(1);
      expect(sel.activate(), isTrue);
      expect(activated, 'b');
      expect(sel.active, isFalse);
      expect(sel.highlightedId, isNull);
      // A second activate is a no-op (cycling already ended).
      expect(sel.activate(), isFalse);
    });

    test('cancel leaves cycling without activating', () {
      final sel = StatusSelection();
      var fired = false;
      sel.register('a', () => fired = true);
      sel.engage();
      sel.cancel();
      expect(sel.active, isFalse);
      expect(fired, isFalse);
    });

    test('unregister clears highlight and stops cycling when empty', () {
      final sel = StatusSelection();
      sel.register('a', () {});
      sel.engage();
      expect(sel.isHighlighted('a'), isTrue);
      sel.unregister('a');
      expect(sel.hasSegments, isFalse);
      expect(sel.active, isFalse);
      expect(sel.highlightedId, isNull);
    });
  });

  group('StatusCycleController', () {
    late FakeStdio io;
    late Screen screen;
    late LineEditor editor;

    setUp(() {
      io = FakeStdio();
      screen = Screen(io: io, layout: ScreenLayout.fromSize(80, 24));
      editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
    });

    Future<void> flush() async {
      await Future<void>.microtask(() {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    // F5 = ESC [ 15 ~
    const f5 = [0x1b, 0x5b, 0x31, 0x35, 0x7e];

    test('F5 engages cycling, Enter activates the highlighted segment', () async {
      final context = ConsoleContext(screen: screen, editor: editor);
      final sel = context.statusSelection;
      var activated = false;
      sel.register('bg', () => activated = true);

      final cycle = StatusCycleController(context);
      final removeModal = context.addModal(cycle);
      final removeShortcut = context.bindShortcut((event) {
        if (event is FunctionKey && event.code == FunctionKeyCode.f5) {
          cycle.toggle();
          return true;
        }
        return false;
      });

      editor.readLine('> ');
      await flush();
      io.feedBytes(f5);
      await flush();
      expect(sel.active, isTrue, reason: 'F5 engages status cycling');
      expect(sel.isHighlighted('bg'), isTrue);

      io.feedBytes([0x0d]); // Enter commits
      await flush();
      expect(activated, isTrue, reason: 'Enter activates the highlighted segment');
      expect(sel.active, isFalse, reason: 'activation ends cycling');

      removeModal();
      removeShortcut();
      editor.close(reportLatency: false);
      screen.dispose();
    });

    test('F5 again (or Esc) cancels cycling without activating', () async {
      final context = ConsoleContext(screen: screen, editor: editor);
      final sel = context.statusSelection;
      var activated = false;
      sel.register('bg', () => activated = true);

      final cycle = StatusCycleController(context);
      final removeModal = context.addModal(cycle);
      final removeShortcut = context.bindShortcut((event) {
        if (event is FunctionKey && event.code == FunctionKeyCode.f5) {
          cycle.toggle();
          return true;
        }
        return false;
      });

      editor.readLine('> ');
      await flush();
      io.feedBytes(f5);
      await flush();
      expect(sel.active, isTrue);
      io.feedBytes([0x1b]); // Esc cancels
      await flush();
      expect(sel.active, isFalse);
      expect(activated, isFalse);

      removeModal();
      removeShortcut();
      editor.close(reportLatency: false);
      screen.dispose();
    });
  });
}
