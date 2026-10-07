# Working-context viewer

`tina/context-tui` is an optional, read-only console companion to `tina/context`.
Enable the context plugin first, then the viewer in Settings → Plugins:

```toml
[plugins.overrides]
"tina/context" = true
"tina/context-tui" = true
```

Restart if `tina/context` was not already loaded. Once it is loaded, the viewer
can be enabled or disabled live. Both plugins are disabled by default.

Use `/context` to open the inspector. Tab (or `T`) cycles through three views:

- **Context** shows accepted working messages as short, collapsible previews.
  User messages are labelled “You”; assistant messages are labelled “Assistant”.
  Tool calls and retained outputs appear together, with readable action names.
- **Changes** summarizes the latest accepted edit and shows collapsible removed
  and added content. Red/minus marks removals; green/plus marks additions.
  Shared leading and trailing messages are hidden. Rewrites and reordering
  appear as removals/additions, not guessed semantic changes.
- **Details** shows revision, session-log position, context-file path, validation
  receipt and the full budget explanation.

Use ↑↓ to select a message or tool exchange, Space/Enter to expand or collapse,
and →/← to open or close it. PgUp/PgDn and mouse scrolling browse long expanded
content. In Details, ↑↓ scroll. Esc closes the inspector and restores the input
draft. Approval and settings readers take priority. Session teardown removes the
modal, cursor ownership and refresh timer.

A compact header shows file status and the last prepared request's estimated
input size against its input budget (total budget minus response reserve).
The default is 32,000 total tokens with a 2,048 response reserve, leaving 29,952
input tokens. A gauge shows the percentage used, including values above 100%;
its bar saturates rather than concealing overflow. It also shows estimated
message-token savings or increases from the latest accepted edit.

The Context view contains accepted working messages; system instructions and
tool definitions are separate and are included in the request gauge. Both
estimates use serialized UTF-8 JSON bytes divided by four, not a provider
tokenizer or billing count. Settings apply to subsequent requests, so the gauge
is labelled as the last prepared request. Budget guidance is not a hard limit.
Details exposes the message-only estimate and response reserve.

Messages follow working-context order, not original turn numbers. Reasoning and
images are indicated without expanding their contents. Expanded payload previews
are bounded; full content remains in the context file. Terminal control
characters are removed before rendering. Color supplements textual labels and
symbols; monochrome mode preserves navigation and meaning.

The changes view is reconstructed from eligible session-log snapshots after
resume. Context reset clears the comparison, and abandoned edits are excluded.

File changes are marked pending until the context plugin validates them before
a model call. Missing or unreadable files are marked separately. The viewer
never imports edits, repairs the mirror, writes a snapshot, or affects provider
requests. It shows accepted state even when the mirror contains invalid JSON.
Rejection receipts remain visible across later unchanged exports, but receipts
are transient and do not survive restart. As with the context plugin itself,
accepted edits survive restart only when persistence is enabled.

Run `dart pub get`, `dart analyze`, and `dart test` in this directory to verify.
