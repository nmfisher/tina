import 'dart:async';

import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

/// Flush microtasks and timers so that async events (timers, completers)
/// have a chance to fire.
Future<void> _flush() async {
  await Future<void>.microtask(() {});
  await Future<void>.microtask(() {});
  await Future<void>.delayed(Duration.zero);
}

/// Drain a standalone ESC. The editor is built with `escapeTimeout:
/// Duration.zero`, so a lone `0x1b` byte's timer fires on the next flush —
/// no real-time wait is needed. Multi-byte sequences (Alt+F, CSI) resolve
/// synchronously inside `feedBytes`, so they never touch this timer.
Future<void> _waitForAltTimer() async {
  await _flush();
}

void main() {
  const W = 100;
  const H = 24;

  group('MenuBar integration', () {
    late FakeStdio io;
    late Screen screen;
    late VirtualTerminal vt;
    late ScreenLayout layout;
    late LineEditor editor;
    late List<String> activations;

    List<Menu> buildMenus() {
      activations = [];
      return [
        Menu(label: 'File', shortcut: 0x66, items: [
          MenuEntry(label: 'New', onActivate: () => activations.add('new')),
          MenuSeparator(),
          MenuEntry(label: 'Exit', shortcutHint: 'Ctrl+C',
              onActivate: () => activations.add('exit')),
        ]),
        Menu(label: 'Edit', shortcut: 0x65, items: [
          MenuEntry(label: 'Undo',
              onActivate: () => activations.add('undo')),
          MenuEntry(label: 'Redo', enabled: false,
              onActivate: () => activations.add('redo')),
        ]),
        Menu(label: 'Help', shortcut: 0x68, items: [
          MenuEntry(label: 'About',
              onActivate: () => activations.add('about')),
        ]),
      ];
    }

    setUp(() {
      io = FakeStdio();
      layout = ScreenLayout.fromSize(W, H, hasMenuBar: true);
      screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
      vt = VirtualTerminal(width: W, height: H);
      screen.redrawFrame();
      vt.feed(io.written.toString());
      io.written.clear();
      activations = [];
      // Duration.zero so a standalone ESC fires on the next flush instead of
      // waiting out the 150ms production default. Multi-byte sequences (Alt+F,
      // CSI) still resolve synchronously inside a single feedBytes call.
      editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
    });

    tearDown(() {
      editor.close();
    });

    // -- Rendering: bar labels appear correctly -----------------------------

    test('render writes menu labels on the menu bar row', () {
      final bar = MenuBar(screen, buildMenus());
      editor.menuBar = bar;
      bar.render();
      vt.feed(io.written.toString());

      final row = vt.rowText(layout.menuBarRow);
      // Labels should appear with space padding.
      expect(row.contains(' File '), isTrue);
      expect(row.contains(' Edit '), isTrue);
      expect(row.contains(' Help '), isTrue);
      // No toString garbage.
      expect(row.contains('Instance'), isFalse);
    });

    // -- F10 activation via bytes -------------------------------------------

    test('F10 activates bar with highlighted label', () async {
      final bar = MenuBar(screen, buildMenus());
      editor.menuBar = bar;
      bar.render();
      vt.feed(io.written.toString());
      io.written.clear();

      editor.readLine('> ');
      await _flush();

      // F10 = ESC [ 2 1 ~
      io.feedBytes([0x1b, 0x5b, 0x32, 0x31, 0x7e]);
      await _flush();
      vt.feed(io.written.toString());

      expect(bar.isActive, isTrue);
      final row = vt.rowText(layout.menuBarRow);
      // Highlighted label includes spaces inside reverse video.
      expect(row.contains('File'), isTrue);
      expect(row.contains('Instance'), isFalse);
      // Unhighlighted labels are dimmed but still present.
      expect(row.contains('Edit'), isTrue);
      expect(row.contains('Help'), isTrue);
    });

    // -- Alt+letter via bytes -----------------------------------------------

    test('Alt+F opens File dropdown via bytes', () async {
      final bar = MenuBar(screen, buildMenus());
      editor.menuBar = bar;
      bar.render();
      editor.readLine('> ');
      await _flush();
      io.written.clear();

      // Alt+F = ESC f
      io.feedBytes([0x1b, 0x66]);
      await _flush();
      vt.feed(io.written.toString());

      expect(bar.isActive, isTrue);
      // Dropdown should show File menu items.
      var foundNew = false;
      for (var r = 0; r < H; r++) {
        if (vt.rowText(r).contains('New')) foundNew = true;
      }
      expect(foundNew, isTrue);
    });

    test('non-matching Alt+Z does not activate menu', () async {
      final bar = MenuBar(screen, buildMenus());
      editor.menuBar = bar;
      bar.render();
      editor.readLine('> ');
      await _flush();
      io.written.clear();

      // Alt+Z = ESC z — no menu has shortcut 'z'.
      io.feedBytes([0x1b, 0x7a]);
      await _flush();

      expect(bar.isActive, isFalse);
    });

    // -- Standalone ESC no longer activates the menu ------------------------

    test('standalone ESC does not activate the menu bar', () async {
      final bar = MenuBar(screen, buildMenus());
      editor.menuBar = bar;
      bar.render();
      editor.readLine('> ');
      await _flush();
      io.written.clear();

      // Standalone ESC — no following byte within 30ms.
      io.feedBytes([0x1b]);
      await _waitForAltTimer();
      vt.feed(io.written.toString());

      // Esc returns focus to chat / arms double-Esc; it no longer opens the
      // menu. Activate via Alt+letter, F10, or the focus ring instead.
      expect(bar.isActive, isFalse);
    });

    // -- Focused (no dropdown) is non-trapping; open dropdown is modal ------

    test('focused bar with no dropdown lets Tab/text/Ctrl-keys fall through',
        () {
      final bar = MenuBar(screen, buildMenus());
      bar.activate(); // active, no dropdown — the ring-focused state
      expect(bar.isActive, isTrue);

      // Tab, Ctrl+G, text, and Ctrl+arrow all fall through (return false) so
      // the focus ring / editor receive them: Tab cycles to the next panel,
      // text reaches the input, Ctrl+arrow does spatial nav.
      expect(bar.handleEvent(ControlKey(ControlCode.tab)), isFalse);
      expect(bar.handleEvent(ControlKey(ControlCode.ctrlG)), isFalse);
      expect(bar.handleEvent(CharInput('x')), isFalse);
      expect(bar.handleEvent(ArrowKey(ArrowDirection.down, hasCtrl: true)),
          isFalse);

      // Plain arrows that operate the bar are still consumed.
      expect(bar.handleEvent(ArrowKey(ArrowDirection.down)), isTrue);
    });

    test('open dropdown is modal — consumes Tab and text', () {
      final bar = MenuBar(screen, buildMenus());
      bar.activate();
      bar.handleEvent(ArrowKey(ArrowDirection.down)); // open the dropdown

      // Now modal: Tab and text are consumed (mnemonic-jump / navigation).
      expect(bar.handleEvent(ControlKey(ControlCode.tab)), isTrue);
      expect(bar.handleEvent(CharInput('x')), isTrue);
    });

    // -- Arrow navigation via bytes -----------------------------------------

    test('arrow down opens dropdown; arrow keys navigate items', () async {
      final bar = MenuBar(screen, buildMenus());
      editor.menuBar = bar;
      bar.render();
      editor.readLine('> ');
      await _flush();

      // F10 to activate.
      io.feedBytes([0x1b, 0x5b, 0x32, 0x31, 0x7e]);
      await _flush();

      // Arrow down to open dropdown.
      io.feedBytes([0x1b, 0x5b, 0x42]); // CSI B = down
      await _flush();
      vt.feed(io.written.toString());

      // Dropdown should be visible with first item "New".
      var foundNew = false;
      for (var r = 0; r < H; r++) {
        if (vt.rowText(r).contains('New')) foundNew = true;
      }
      expect(foundNew, isTrue);

      // Arrow down again — skip separator, land on Exit.
      io.feedBytes([0x1b, 0x5b, 0x42]);
      await _flush();
      io.written.clear();

      // Enter to activate.
      io.feedBytes([0x0d]);
      await _flush();
      // The menu bar eats Enter, so it shouldn't submit the line.
      // Instead it activates the Exit menu item.
      expect(activations, ['exit']);
      expect(bar.isActive, isFalse);
    });

    test('arrow right moves between menus', () async {
      final bar = MenuBar(screen, buildMenus());
      editor.menuBar = bar;
      bar.render();
      editor.readLine('> ');
      await _flush();

      // F10 to activate (File highlighted).
      io.feedBytes([0x1b, 0x5b, 0x32, 0x31, 0x7e]);
      await _flush();

      // Arrow right → Edit.
      io.feedBytes([0x1b, 0x5b, 0x43]); // CSI C = right
      await _flush();

      // Arrow down to open Edit dropdown.
      io.feedBytes([0x1b, 0x5b, 0x42]);
      await _flush();
      vt.feed(io.written.toString());

      // Should show Undo.
      var foundUndo = false;
      for (var r = 0; r < H; r++) {
        if (vt.rowText(r).contains('Undo')) foundUndo = true;
      }
      expect(foundUndo, isTrue);

      // Enter activates Undo.
      io.feedBytes([0x0d]);
      await _flush();
      expect(activations, ['undo']);
    });

    test('arrow left wraps to last menu', () async {
      final bar = MenuBar(screen, buildMenus());
      editor.menuBar = bar;
      bar.render();
      editor.readLine('> ');
      await _flush();

      // F10 to activate (File).
      io.feedBytes([0x1b, 0x5b, 0x32, 0x31, 0x7e]);
      await _flush();

      // Arrow left → wraps to Help.
      io.feedBytes([0x1b, 0x5b, 0x44]); // CSI D = left
      await _flush();

      // Arrow down to open Help dropdown.
      io.feedBytes([0x1b, 0x5b, 0x42]);
      await _flush();
      io.written.clear();

      // Enter activates About.
      io.feedBytes([0x0d]);
      await _flush();
      expect(activations, ['about']);
    });

    test('arrow up wraps from top to bottom item', () async {
      final bar = MenuBar(screen, buildMenus());
      editor.menuBar = bar;
      bar.render();
      editor.readLine('> ');
      await _flush();

      // Alt+F opens File dropdown (New selected at index 0).
      io.feedBytes([0x1b, 0x66]);
      await _flush();

      // Arrow up — wraps to Exit (index 2, skipping separator).
      io.feedBytes([0x1b, 0x5b, 0x41]); // CSI A = up
      await _flush();

      // Enter activates Exit.
      io.feedBytes([0x0d]);
      await _flush();
      expect(activations, ['exit']);
    });

    // -- ESC deactivation via bytes -----------------------------------------

    test('ESC closes dropdown, second ESC deactivates bar', () async {
      final bar = MenuBar(screen, buildMenus());
      editor.menuBar = bar;
      bar.render();
      editor.readLine('> ');
      await _flush();

      // Alt+F opens File dropdown.
      io.feedBytes([0x1b, 0x66]);
      await _flush();

      // Standalone ESC — timer fires → EscapeKey → closes dropdown.
      io.feedBytes([0x1b]);
      await _waitForAltTimer();

      expect(bar.isActive, isTrue); // bar still active, dropdown closed

      // Second standalone ESC — timer fires → deactivates bar.
      io.feedBytes([0x1b]);
      await _waitForAltTimer();

      expect(bar.isActive, isFalse);
    });

    test('F10 toggles menu off when active', () async {
      final bar = MenuBar(screen, buildMenus());
      editor.menuBar = bar;
      bar.render();
      editor.readLine('> ');
      await _flush();

      // F10 activates.
      io.feedBytes([0x1b, 0x5b, 0x32, 0x31, 0x7e]);
      await _flush();
      expect(bar.isActive, isTrue);

      // F10 again deactivates.
      io.feedBytes([0x1b, 0x5b, 0x32, 0x31, 0x7e]);
      await _flush();
      expect(bar.isActive, isFalse);
    });

    // -- Mnemonic char activates matching item ------------------------------

    test('typing char while dropdown open activates matching item', () async {
      final bar = MenuBar(screen, buildMenus());
      editor.menuBar = bar;
      bar.render();
      editor.readLine('> ');
      await _flush();

      // Alt+F opens File dropdown.
      io.feedBytes([0x1b, 0x66]);
      await _flush();

      // Type 'E' — matches "Exit".
      io.feedBytes([0x45]); // 'E'
      await _flush();
      expect(activations, ['exit']);
      expect(bar.isActive, isFalse);
    });

    // -- Dropdown rendering -------------------------------------------------

    test('dropdown renders item labels, borders, and separator', () async {
      final bar = MenuBar(screen, buildMenus());
      editor.menuBar = bar;
      bar.render();
      editor.readLine('> ');
      await _flush();
      io.written.clear();

      // Alt+F opens File dropdown.
      io.feedBytes([0x1b, 0x66]);
      await _flush();
      vt.feed(io.written.toString());

      // Find the dropdown rows — they should contain box-drawing borders
      // and item labels.
      var foundBorder = false;
      var foundNew = false;
      var foundExit = false;
      var foundShortcut = false;
      var foundSeparator = false;
      for (var r = 0; r < H; r++) {
        final row = vt.rowText(r);
        if (row.contains('New')) foundNew = true;
        if (row.contains('Exit')) foundExit = true;
        if (row.contains('Ctrl+C')) foundShortcut = true;
        if (row.contains('┌')) foundBorder = true;
        // The dropdown separator draws ├────┤. We check ┤ rather than ├
        // because the dropdown sits at col 0 where the chat box's border
        // repair overwrites the left glyph; ┤ lands inside the interior
        // and survives. Either way it proves the separator row rendered.
        if (row.contains('┤')) foundSeparator = true;
      }
      expect(foundNew, isTrue);
      expect(foundExit, isTrue);
      expect(foundShortcut, isTrue);
      expect(foundBorder, isTrue);
      expect(foundSeparator, isTrue);
    });

    test('dropdown item text aligns with bar label text', () async {
      final bar = MenuBar(screen, buildMenus());
      editor.menuBar = bar;
      bar.render();
      editor.readLine('> ');
      await _flush();
      vt.feed(io.written.toString()); // render bar into VT

      // Find the column of 'F' in "File" on the bar row.
      final barRow = layout.menuBarRow;
      final barText = vt.rowText(barRow);
      final fCol = barText.indexOf('File');
      expect(fCol, greaterThanOrEqualTo(0), reason: '"File" not found on bar');

      io.written.clear();

      // Alt+F opens File dropdown (New / --- / Exit Ctrl+C).
      io.feedBytes([0x1b, 0x66]);
      await _flush();
      vt.feed(io.written.toString());

      // Find the row containing "New" in the dropdown.
      var newCol = -1;
      for (var r = 0; r < H; r++) {
        final row = vt.rowText(r);
        final idx = row.indexOf('New');
        if (idx >= 0) { newCol = idx; break; }
      }
      expect(newCol, greaterThanOrEqualTo(0), reason: '"New" not found in dropdown');

      // The first character of the dropdown item must align with the first
      // character of the menu label.
      expect(newCol, fCol,
          reason: '"New" should start at the same column as "File" '
              '("New" at col $newCol, "File" at col $fCol)');

      // Also check "Exit" aligns.
      var exitCol = -1;
      for (var r = 0; r < H; r++) {
        final row = vt.rowText(r);
        final idx = row.indexOf('Exit');
        if (idx >= 0) { exitCol = idx; break; }
      }
      expect(exitCol, fCol,
          reason: '"Exit" should start at the same column as "File"');
    });

    test('disabled items appear dimmed in dropdown', () async {
      final bar = MenuBar(screen, buildMenus());
      editor.menuBar = bar;
      bar.render();
      editor.readLine('> ');
      await _flush();
      io.written.clear();

      // Alt+E opens Edit dropdown (Undo=enabled, Redo=disabled).
      io.feedBytes([0x1b, 0x65]);
      await _flush();
      vt.feed(io.written.toString());

      // Redo should be present but dimmed (ANSI dim code \x1b[2m).
      var foundRedo = false;
      for (var r = 0; r < H; r++) {
        if (vt.rowText(r).contains('Redo')) foundRedo = true;
      }
      expect(foundRedo, isTrue);
      // The raw output should contain the dim ANSI code.
      expect(io.written.toString().contains('\x1b[2m'), isTrue);
    });

    // -- Edge cases ---------------------------------------------------------

    test('empty menu list does not crash on F10', () async {
      final bar = MenuBar(screen, []);
      editor.menuBar = bar;
      bar.render();
      editor.readLine('> ');
      await _flush();

      io.feedBytes([0x1b, 0x5b, 0x32, 0x31, 0x7e]);
      await _flush();
      expect(bar.isActive, isFalse);
    });

    test('dropdown with no items hides immediately', () async {
      final bar = MenuBar(screen, [
        Menu(label: 'Empty', shortcut: 0x65, items: []),
      ]);
      editor.menuBar = bar;
      bar.render();
      editor.readLine('> ');
      await _flush();

      // Alt+E opens Empty dropdown — no items to show.
      io.feedBytes([0x1b, 0x65]);
      await _flush();
      expect(bar.isActive, isTrue);
      // No crash.
    });

    test('deactivate closes dropdown and restores bar', () async {
      final bar = MenuBar(screen, buildMenus());
      editor.menuBar = bar;
      bar.render();
      editor.readLine('> ');
      await _flush();

      io.feedBytes([0x1b, 0x66]);
      await _flush();

      bar.deactivate();
      vt.feed(io.written.toString());
      expect(bar.isActive, isFalse);
    });

    // -- macOS Option key integration ----------------------------------------

    test('macOS Option+F bytes (ƒ) open File dropdown via LineEditor pipeline',
        () async {
      // Construct an editor with macosOptionAsMeta enabled, exercising the
      // full _onBytes → parser → _dispatchEvent → MenuBar path.
      final optEditor = LineEditor(
        screen: screen,
        macosOptionAsMeta: true,
      );
      final bar = MenuBar(screen, buildMenus());
      optEditor.menuBar = bar;
      bar.render();
      optEditor.readLine('> ');
      await _flush();
      io.written.clear();

      // Option+F produces ƒ (U+0192), UTF-8: 0xC6 0x92.
      io.feedBytes([0xC6, 0x92]);
      await _flush();

      expect(bar.isActive, isTrue, reason: 'Option+F should activate menu bar');
      // Dropdown should show "New" from the File menu.
      var foundNew = false;
      vt.feed(io.written.toString());
      for (var r = 0; r < H; r++) {
        if (vt.rowText(r).contains('New')) foundNew = true;
      }
      expect(foundNew, isTrue, reason: 'File dropdown should show "New"');

      optEditor.close();
    });
  });
}
