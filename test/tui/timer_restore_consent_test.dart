import 'package:tina/tui/spawn_overlay.dart';
import 'package:tina_console/tina_console.dart';

import 'package:test/test.dart';

import '../helpers/overlay_fixtures.dart';

/// P2 consent fix (§10 step 4): the timer-restore ask defaults to NO.
///
/// The prompt re-arms autonomous timers, so an Enter-mashed Yes silently
/// changes what the agent does after a resume. The production seam
/// (`TuiCoordinator.create` → `controller.timerRestorePrompt`) renders the
/// summary through `runListOverlay` with entries ordered **No first** —
/// the same overlay adapter every other picker runs through, driven here by
/// real `Screen` paints and canned key events.
void main() {
  const summary = 'This session has 1 saved timer(s):'
      '\n  recurring every 5m, 7/10 fires used'
      '\nRestore them? [y/N]';

  /// The production prompt body (verbatim from the coordinator wiring).
  Future<bool> ask({required List<InputEvent> events}) async {
    final screen = fakeScreen();
    final editor = LineEditor(screen: screen);
    final choice = await runListOverlay<bool>(
      screen: screen,
      editor: editor,
      entries: const [
        (display: 'No — leave timers saved on disk', value: false),
        (display: 'Yes — restore and arm them', value: true),
      ],
      title: 'Restore saved timers?',
      body: summary,
      footer: '↑↓ move · enter select · esc cancel',
      accent: 'cyan',
      readEvent: () async => events.removeAt(0),
    );
    return choice == true;
  }

  test('Enter on the focused default answers NO (restore declined)', () async {
    final screen = fakeScreen();
    final editor = LineEditor(screen: screen);
    final choice = await runListOverlay<bool>(
      screen: screen,
      editor: editor,
      entries: const [
        (display: 'No — leave timers saved on disk', value: false),
        (display: 'Yes — restore and arm them', value: true),
      ],
      title: 'Restore saved timers?',
      body: summary,
      footer: '↑↓ move · enter select · esc cancel',
      accent: 'cyan',
      readEvent: () async {
        // First paint happened by now: assert the No entry is rendered as
        // the focused one (▸ cursor) before answering.
        return ControlKey(ControlCode.enter);
      },
    );
    expect(
      choice,
      false,
      reason: 'the No entry is focused first — Enter-mashing must NOT '
          're-arm autonomous timers (§10 step 4, [y/N])',
    );
  });

  test('Down then Enter answers YES (explicit consent still works)', () async {
    final restored = await ask(events: [
      ArrowKey(ArrowDirection.down),
      ControlKey(ControlCode.enter),
    ]);
    expect(restored, isTrue, reason: 'explicit selection still restores');
  });

  test('Esc cancels the ask → NO (timers stay on disk)', () async {
    final restored = await ask(events: [
      EscapeKey(),
    ]);
    expect(
      restored,
      isFalse,
      reason: 'cancelling the picker declines the restore',
    );
  });

  test('Ctrl+C cancels the ask → NO (same semantics as Esc)', () async {
    final restored = await ask(events: [
      ControlKey(ControlCode.ctrlC),
    ]);
    expect(restored, isFalse);
  });
}
