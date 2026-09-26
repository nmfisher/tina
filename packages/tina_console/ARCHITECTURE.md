# tina_console

The terminal toolkit behind tina's UI: a `Screen` with clipped regions, a
line editor, focus and panel plumbing, input parsing, and the backend
abstraction (ANSI escapes or notcurses). It knows nothing about agents,
tools, or git — only strings, rectangles, and bytes.

## Layout

```
lib/
  tina_console.dart     public barrel (+ testing.dart for fakes)
  src/
    screen.dart              the single writer: dirty-region, clipped output
    screen_layout.dart       one layout value object shared by everything
    region.dart / rect.dart  clipped output rectangles
    renderer.dart            pure renderer inputs/outputs (RenderRow, spans)
    styled_text.dart / theme.dart / terminal_bg.dart
    status_layout.dart       pure status-strip layout inputs
    line_editor.dart / line_layout.dart / text_line_input.dart / text_buffer.dart
    input_parser.dart / input_event.dart    bytes → key/mouse/paste events
    completion_picker.dart / confirm_dialog.dart / menu_bar.dart
    conversation_panel.dart / panel.dart / text_panel.dart / info_panel.dart
    focusable.dart / focus_manager.dart     focus routing
    modal_surface.dart / spinner.dart / comet.dart / tool_chip.dart
    stdio.dart / term_width.dart / input_latency.dart / paste_audit.dart
    backend/                 TerminalBackend / InputBackend implementations
```

## The rules that keep rendering sane

- **`Screen` is the chokepoint.** Every byte to the terminal passes through
  `Screen` → `TerminalBackend`. Cursor position is computed inside the
  screen; nothing else tracks it.
- **Regions clip on every write.** A `Region` cannot emit ANSI or move the
  cursor — its only output path is `screen.putAtAbsolute(...)`, which clips
  and repairs borders. A new overlay type is one subclass.
- **Renderers are pure.** Inputs (width, theme, state) → rows of styled
  spans. Status strips and plugin status renderers are functions from a
  `StatusLayoutInput` to rows, so plugins can replace the layout.
- **Themes are data.** Every style comes from `theme.dart` via
  `Screen.setTheme`, cached per theme version.

## Backends and input

`Screen` delegates to a `TerminalBackend` — ANSI escapes or notcurses,
selected at startup by a safe FFI probe (`notcurses_probe.dart`), ANSI as
fallback. A parallel `InputBackend` decouples the editor from the byte
source. The backend directory also holds the paste-burst detector and
reply-sequence filter that make bracketed paste and probe replies safe.

Input path: bytes → `input_parser.dart` → `InputEvent`s →
`focus_manager.dart` → the focused widget. `paste_audit.dart` +
`input_latency.dart` are the observability layer for paste truncation and
latency bugs.

Fuzzy scoring lives in `packages/fuzzy_ranker`; this package owns the
picker UI only. `Screen` and regions are concrete — one implementation,
`Screen.passthrough(...)` covers the only second mode (non-TTY). The line
editor's keymap is hardcoded; one consumer.
