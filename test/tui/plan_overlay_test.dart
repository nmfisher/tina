import 'package:tina/tui/plan_overlay.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import '../helpers/overlay_fixtures.dart';

/// The plan overlay: pure renderer goldens + the non-modal host against a
/// fake-screen [Screen]. The host is keyboard-free, so the observable
/// behavior is region visibility and the painted bounds.
void main() {
  group('renderPlanOverlayLines', () {
    test('expanded: bordered box with per-state icon rows and a footer',
        () {
      final plan = Plan([
        (text: 'read tests', state: PlanState.done),
        (text: 'fix regex', state: PlanState.inProgress),
        (text: 'release', state: PlanState.pending),
      ]);
      final lines = renderPlanOverlayLines(
        plan: plan,
        ui: const PlanOverlayUi(),
        width: 30,
        paint: (text, code) => code == null ? text : '@$text@',
      );
      expect(lines, hasLength(6)); // top border + 3 items + footer + bottom
      expect(lines.first.split('@').join(''), startsWith('┌'));
      expect(lines.first, contains('plan · 1/3'));
      expect(lines.join('\n'), contains('@▸ fix regex@'));
      expect(lines.join('\n'), contains('@✓ read tests@'));
      expect(lines.join('\n'), contains('· release'));
      expect(lines.last.split('@').join(''), startsWith('└'));
      expect(lines.last.split('@').join(''), endsWith('┘'));
      expect(lines.join('\n'), contains('ctrl+p collapse'));
    });

    test('approval badge appears in the header', () {
      final plan = Plan(
        [(text: 'a', state: PlanState.pending)],
        approval: PlanApproval.requested,
      );
      final lines = renderPlanOverlayLines(
        plan: plan,
        ui: const PlanOverlayUi(),
        width: 34, // fits ' plan · 0/1 · needs approval ' un-ellipsized
        paint: (t, _) => t,
      );
      expect(lines.first, contains('needs approval'));
    });

    test('approved plan says approved; rejected says rejected', () {
      String header(PlanApproval approval) {
        final lines = renderPlanOverlayLines(
          plan: Plan([(text: 'a', state: PlanState.pending)],
              approval: approval),
          ui: const PlanOverlayUi(),
          width: 30,
          paint: (t, _) => t,
        );
        return lines.first;
      }

      expect(header(PlanApproval.approved), contains('approved'));
      expect(header(PlanApproval.rejected), contains('rejected'));
    });

    test('collapsed: only the active row is shown, footer says expand',
        () {
      final plan = Plan([
        (text: 'read tests', state: PlanState.done),
        (text: 'fix regex', state: PlanState.inProgress),
        (text: 'release', state: PlanState.pending),
      ]);
      final lines = renderPlanOverlayLines(
        plan: plan,
        ui: const PlanOverlayUi(collapsed: true),
        width: 30,
        paint: (t, _) => t,
      );
      expect(lines, hasLength(4)); // top + 1 row + footer + bottom
      expect(lines.join('\n'), contains('▸ fix regex'));
      expect(lines.join('\n'), isNot(contains('read tests')));
      expect(lines.join('\n'), contains('ctrl+p expand'));
    });

    test('collapsed without an active item still renders one row', () {
      final plan = Plan([(text: 'a', state: PlanState.pending)]);
      final lines = renderPlanOverlayLines(
        plan: plan,
        ui: const PlanOverlayUi(collapsed: true),
        width: 30,
        paint: (t, _) => t,
      );
      // top border + footer + bottom border (no active row)
      expect(lines, hasLength(3));
    });

    test('long item text is ellipsized to the box width', () {
      final plan = Plan([
        (text: 'x' * 200, state: PlanState.pending),
      ]);
      final lines = renderPlanOverlayLines(
        plan: plan,
        ui: const PlanOverlayUi(),
        width: 30,
        paint: (t, _) => t,
      );
      final row = lines[1];
      expect(row.length, lessThan(40));
      expect(row, contains('…'));
    });

    test('narrow width below the minimum renders nothing', () {
      final plan = Plan([(text: 'a', state: PlanState.pending)]);
      expect(
        renderPlanOverlayLines(
          plan: plan,
          ui: const PlanOverlayUi(),
          width: 4,
          paint: (t, _) => t,
        ),
        isEmpty,
      );
    });
  });

  group('planOverlayContentHeight', () {
    test('expanded counts every item + footer', () {
      final plan = Plan([
        (text: 'a', state: PlanState.pending),
        (text: 'b', state: PlanState.pending),
      ]);
      expect(planOverlayContentHeight(plan, collapsed: false), 3);
    });

    test('collapsed counts the active row only when present', () {
      final withActive = Plan([
        (text: 'a', state: PlanState.inProgress),
        (text: 'b', state: PlanState.pending),
      ]);
      final without = Plan([(text: 'b', state: PlanState.pending)]);
      expect(planOverlayContentHeight(withActive, collapsed: true), 3);
      expect(planOverlayContentHeight(without, collapsed: true), 2);
    });
  });

  group('PlanOverlay (host)', () {
    late PlanStore store;
    setUp(() => store = PlanStore());
    tearDown(() => store.dispose());

    PlanOverlay overlay(Screen screen,
            {PlanOverlayMode mode = PlanOverlayMode.auto}) =>
        PlanOverlay(
          screen: screen,
          store: store,
          conversationId: () => 'c1',
          mode: mode,
        );

    test('auto mode paints when a plan exists; hides when cleared', () {
      final screen = fakeScreen();
      final o = overlay(screen)..start();
      expect(o.regionVisible, isFalse, reason: 'no plan yet');
      store.update('c1', [(text: 'a', state: PlanState.inProgress)]);
      o.refresh();
      expect(o.regionVisible, isTrue);
      store.clear('c1');
      o.refresh();
      expect(o.regionVisible, isFalse);
      o.dispose();
    });

    test('only the focused conversation drives the box', () {
      final screen = fakeScreen();
      var focused = 'c1';
      final o = PlanOverlay(
        screen: screen,
        store: store,
        conversationId: () => focused,
      )..start();
      store.update('c2', [(text: 'other', state: PlanState.pending)]);
      o.refresh();
      expect(o.regionVisible, isFalse);
      focused = 'c2';
      o.refresh();
      expect(o.regionVisible, isTrue);
      o.dispose();
    });

    test('manual mode stays hidden until Ctrl+P toggles it', () {
      final screen = fakeScreen();
      final o = overlay(screen, mode: PlanOverlayMode.manual)..start();
      store.update('c1', [(text: 'a', state: PlanState.pending)]);
      o.refresh();
      expect(o.regionVisible, isFalse);
      o.toggle();
      expect(o.regionVisible, isTrue);
      o.toggle();
      expect(o.regionVisible, isFalse);
      o.dispose();
    });

    test('Ctrl+P reaches the overlay through the editor hook', () {
      final screen = fakeScreen(columns: 80, lines: 24);
      final o = overlay(screen)..start();
      store.update('c1', [(text: 'a', state: PlanState.inProgress)]);
      o.refresh(); // the store's broadcast is async; poll like the host does
      expect(o.regionVisible, isTrue, reason: 'auto mode shows it immediately');

      final editor = LineEditor(screen: screen);
      editor.onPlanToggle = () {
        o.toggle();
        return true;
      };
      expect(editor.onPlanToggle!(), isTrue, reason: 'the key is consumed');
      // Auto mode was showing it, so the first press hides (user override).
      expect(o.regionVisible, isFalse);
      // A plan change must not override the user's hide.
      o.refresh();
      expect(o.regionVisible, isFalse);

      // Second press: show again; third: hide.
      editor.onPlanToggle!();
      expect(o.regionVisible, isTrue);
      editor.onPlanToggle!();
      expect(o.regionVisible, isFalse);
      o.dispose();
    });

    test('an auto-mode user override survives later refreshes', () {
      final screen = fakeScreen();
      final o = overlay(screen)..start();
      store.update('c1', [(text: 'a', state: PlanState.pending)]);
      o.refresh();
      expect(o.regionVisible, isTrue);
      o.toggle(); // hide, despite auto
      expect(o.regionVisible, isFalse);
      store.update('c1', [(text: 'b', state: PlanState.pending)]);
      o.refresh(); // a plan change must not override the user
      expect(o.regionVisible, isFalse);
      o.toggle();
      expect(o.regionVisible, isTrue);
      o.dispose();
    });

    test('a plan taller than the chat area renders collapsed', () {
      final screen = fakeScreen(columns: 80, lines: 24);
      final o = overlay(screen)..start();
      store.update('c1', [
        for (var i = 0; i < 40; i++)
          (text: 'item $i', state: PlanState.pending),
      ]);
      o.refresh();
      expect(o.regionVisible, isTrue);
      final bounds = o.bounds!;
      // 24-row terminal, no menu bar: chat interior is ~20 rows; the
      // collapsed box is 5 rows (border + 1 item + footer + border + spare).
      expect(bounds.height, lessThan(10));
      o.dispose();
    });

    test('dispose removes the region', () {
      final screen = fakeScreen();
      final o = overlay(screen)..start();
      store.update('c1', [(text: 'a', state: PlanState.pending)]);
      o.refresh();
      o.dispose();
      expect(o.regionVisible, isFalse);
    });
  });
}
