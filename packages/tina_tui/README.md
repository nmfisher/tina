# tina_tui — tina's terminal views

Renderer-first views for tina's terminal UI, split out of the app so the
next engine (`tina_engine_2`) can adopt the same UI without inheriting
`tina_engine`. **Views only**: every type here is a pure value-to-rows
rendering or a state holder fed by events. Nothing in this package opens a
terminal, so every behavior is testable headless.

## Layering

```
dart_notcurses
      │
tina_console        generic toolkit: Screen, Region, RenderLine/Run,
      │             Renderer<T>, StatusLayout, ToolChip, Theme
      │
tina_tui            THIS PACKAGE: tina's views — chat transcript, live
      │             stream, tool chips, status strip, approval dialog
      │
bin/tina.dart       composition + the terminal host
```

- **tina_console** knows nothing about agents: it moves bytes to a terminal
  and clips them to regions. Its types are generic.
- **tina_tui** depends on `tina_console` (rendering vocabulary + `ToolChip`)
  and `tina_core` (value types) — and on nothing else. No `tina_engine`, no
  `tina_app`.
- **The app** composes: it owns the `Screen`, mounts these views, and paints
  their rows where its layout says.

## The views

| File | Consumes | Produces |
| --- | --- | --- |
| `chat_view.dart` | a settled `tina_core.Message` | `RenderLine`s |
| `stream_view.dart` | `tina_core.StreamEvent`s, as they arrive | `RenderLine`s (getter) |
| `tool_chip_view.dart` | a `ToolUse` + optional `ToolResult` | one chip line (+ output line) |
| `status_strip.dart` | a `StatusStripState` (mode label + plugin lines) | strip rows |
| `approval_dialog.dart` | a pending `ToolUse` + scripted/real keys | an `ApprovalOutcome` |

Row idiom follows the current terminal: user text bold, agent prose default,
reasoning and tool calls dim (`⏺ name args`), chips colored by lifecycle
state (running dim, success green, error red — the color comes from
`tina_console`'s `ToolChip.state`, which this package drives, never
duplicates).

## Wiring the engine later (intended, not implemented here)

**Provider decorator.** `StreamView` is deliberately a `StreamEvent`
consumer with no terminal, so a `LlmProvider` decorator can tee the events
into it while the loop consumes the same stream:

```dart
class TuiProvider extends LlmProvider {
  // ... delegates send(); tee(StreamEvent e) => view.apply(e);
}
```

**Approval.** `ApprovalDialog` takes any `KeySource` — in production a
raw-mode host maps its parsed input events to `ApprovalKey`s; in tests a
`ScriptedKeySource`. The loop side awaits it from a `beforeTool`-style
permission guard; no new engine hook is needed. A cancelled or closed
dialog denies: **never** a silent allow.

**Status strip.** `statusStripRows` mirrors tina_console's `StatusLayout`
contract (pure data in, rows out); the painter accepts its output lines
unchanged. A plugin can replace the arrangement later by registering a
`StatusLayout`; the painter, not this function, owns where the strip sits.

## Tests

```sh
cd packages/tina_tui && dart test
```

All tests are headless: scripted `StreamEvent`s, scripted keys, pure
row-to-string assertions. 32 tests as of this package's first commit.

## Not here (yet, on purpose)

- No `Screen`/host: painting, scrolling and focus stay in the app.
- No markdown rendering: agent prose here is plain text rows; the app's
  markdown renderer remains where it is.
- No persistence, session, or provider code.
