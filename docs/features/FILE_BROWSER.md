# Plan: standalone directory/file browser (`/browse`)

## Context

Today the only file-selection UI is the flat, fuzzy `@` picker (`GitFileCompletionProvider`)
— there is **no directory browser**. This adds a standalone file browser that starts at the
filesystem root and lets the user navigate the tree. For now it is not wired into the `@`
input; it surfaces as a `/browse` slash command that pops up a panel, lets the user browse,
and echoes the selected file's absolute path. It is built as a reusable overlay primitive so a
later change can plug its result into the chat input or context.

### Design decisions (confirmed)

- Start directory = filesystem root `/` (configurable `startDir` param, defaults to `/`).
- Enter / → descends into a directory, or selects a file (closes + returns its path).
- ← / Backspace goes to the parent (root's parent is itself → no-op reload).
- Esc / Ctrl-C cancels → returns null.
- Entries: dirs first (alphabetical, cyan, trailing `/`), then files (alphabetical, plain).
  Hidden files (leading `.`) skipped.
- Footer shows the focused entry: `dir · <name>` or `file · <human size>`.
- No type-to-filter in v1 — navigate only.

## Building blocks to reuse

- **`OverlayRegion`** (`packages/tina_console/lib/src/region.dart:961`) — floating rect
  surface; `show(List<String> lines)` / `hide()` / `dispose()`.
- **Scrollable-list state machine** from `_ListPickerForm`
  (`lib/tui/spawn_overlay.dart:167`): `_focus` / `_scrollOffset` / `_ensureFocusVisible()` /
  `_dispatch()` / the centered box sizing in `run()` (width `clamp(w-4,40,70)`, height
  `h~/2`). Replicate its logic (it is file-private) rather than inherit.
- **`screen.colorize(code, text)`** (`packages/tina_console/lib/src/screen.dart:567`) + theme
  SGR strings: `theme.chat.cyan` (dirs), `theme.completion.dim` (files),
  `theme.completion.selected` (focus highlight / reverse), `theme.border.focus` for the frame
  accent.
- **`modalTakeFocus` / `modalRestoreFocus`** (`lib/tui/spawn_overlay.dart:121-136`) — not needed
  here; like `runListOverlay`, the browser runs its own `editor.readKey` loop.
- **Slash-command seam**: `SessionCommandHandlers.allCommands` + the `dispatch` switch
  (`lib/session_commands/session_command_handlers.dart`), `CommandContext`
  (`lib/session_commands/command_context.dart`), and the `controller.openX = ...` wires in
  `lib/tui_coordinator.dart`.
- **Test harness**: `CannedEvents` + `fakeScreen()` + `overlayTimeout` from
  `test/helpers/overlay_fixtures.dart`.

## Files to create / modify

### 1. NEW: `lib/tui/browse_panel.dart`
The standalone overlay. Public entry:

```dart
Future<String?> runBrowsePanel({
  required Screen screen,
  required LineEditor editor,
  Directory? startDir,          // default Directory('/')
  Future<InputEvent> Function()? readEvent,
});
```

Private `_BrowserForm` (mirrors `_ListPickerForm`):
- State: `Directory _dir`, `List<FileSystemEntity> _entries`, `String? _listError`,
  `int _focus`, `int _scrollOffset`, `String? _selected`.
- `run()`: size a centered `Rect`, build `OverlayRegion`, call `_load()` once, then
  `while(true){ ev = await _readEvent(); ... _render(); }`. Cancel → null (Esc/Ctrl-C);
  select → absolute path.
- `_load()`: `_entries = await _dir.list(followLinks:false).toList()` (sorted: dirs-first then
  files, alpha by basename; drop names starting with `.`); catch → `_listError` set so the body
  shows one dim `(permission denied)` row.
- `_dispatch(InputEvent)`:
  - `ArrowKey up/down` → move `_focus`, `_ensureFocusVisible()`; `pageUp/pageDown` → by page.
  - `enter` / `arrowRight`: focused entry is `Directory` → `_dir = it; _load(); _focus=0;
    _scrollOffset=0`; is `File`/`Link` → `_selected = it.path; return true`.
  - `arrowLeft` / `backspace` → `_dir = _dir.parent; _load(); reset focus/scroll`.
    (root.parent == root.)
  - `escape` / `ctrlC` → cancel.
- `_render()`: framed box. Title row = absolute `_dir.path`. Body rows from `_scrollOffset`,
  focused row uses `_focusMark` (`▸`) + `theme.completion.selected`; dirs
  `colorize(theme.chat.cyan, '$name/')`; files plain; long names truncated with leading `…`.
  Footer = focused entry: `dir · name` or `file · <formatBytes(size)>` via `statSync()`. Exactly
  `_rect.height` lines (overflow `↑ / ↓ more` hints on the last body rows, matching
  `_ListPickerForm._body`). Border drawn with box-drawing chars (`┌─┐│└┘`) +
  `screen.colorize(activeAccent(screen), ch)` — i.e. `theme.border.focus`.
- Private `formatBytes(int)` → `B`/`KB`/`MB`/`GB`/`TB`.

Note: `lib/tui/` may import `dart:io` (already done by `prompts_overlay.dart`) and
`tina_console` (front-end package; `lib/tui` is an allowed front-end dir, not in
`import_boundary_test.dart`'s `_guarded`).

### 2. MODIFY: `lib/session_commands/session_command_handlers.dart`
- Add `'/browse'` to `allCommands` (~line 19) — this also enrolls it in the `/` completion
  palette and is the dispatch key.
- Add `case '/browse': await _handleBrowse();` in the `dispatch` switch, matching the existing
  grouped-case style (no `break` — the switch ends right after the last case).
- Add `_handleBrowse()`:
  ```dart
  Future<void> _handleBrowse() async {
    final open = ctx.openBrowse;
    if (open == null) {
      ctx.active.host.showMessage('/browse needs the interactive TUI.\n',
          style: HostMessageStyle.warning);
      return;
    }
    await open();
  }
  ```
- Add a `/browse` line to `_printHelp()` (~line 322).

### 3. MODIFY: `lib/session_commands/command_context.dart`
- Add `Future<void> Function()? get openBrowse;` (mirror `openSpawn`, ~line 54).

### 4. MODIFY: `lib/tui_coordinator.dart`
In the `create` block where the other `controller.openX = ...` wires live (after `openImage`,
~line 676):
```dart
controller.openBrowse = () async {
  final path = await runBrowsePanel(screen: screen, editor: editor);
  if (path == null) return;
  controller.active.host.showMessage('selected: $path\n',
      style: HostMessageStyle.success);
};
```

### 5. NEW: `test/tui/browse_panel_test.dart`
Reuse `fakeScreen()`, `CannedEvents`, `overlayTimeout`, `TempTinaDir` from
`overlay_fixtures.dart`. Build a temp tree (dirs, nested files, a hidden file, an empty subdir).
Drive `runBrowsePanel(screen, editor, startDir: tmp)` with canned events:
- Descend into a dir (Enter), then select a file → expect returned == that file's absolute path.
- Navigate down past a page with scroll → footer updates, overflow hints appear.
- Enter at focus 0 on a dir descends; ← / Backspace returns to parent.
- Esc at top → null.
- Hidden file (`.foo`) never appears in rendered body.
- A non-readable dir (or forced `_listError`) → body shows `(permission denied)` dim row
  without throwing.
- Root parent is root: ← at `/` keeps `/`.

## Verification

- `dart test test/tui/browse_panel_test.dart` → all green.
- `dart test test/tui/` → existing overlay tests still green.
- `dart analyze lib/tui/browse_panel.dart lib/session_commands/*.dart lib/tui_coordinator.dart
  lib/session_commands/command_context.dart` → no issues.
- Full suite: `dart test` (currently ~276 passing) → stays green.
- Manual: run the app, type `/browse`, confirm a centered panel rooted at `/`, descend/select/
  echo works, Esc cancels. Then point `startDir` at a project to sanity-check footer sizes +
  dir coloring.

## Out of scope (future integration, not now)

- Injecting the selected path into the chat input or `@` context.
- Type-to-filter, multi-select, symlink-follow display, file-type icons, git-awareness.
- Opening files on Enter in an editor.
