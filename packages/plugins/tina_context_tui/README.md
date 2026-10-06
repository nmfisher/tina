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

Use `/context` to open the panel. Up/down, mouse scrolling, and PgUp/PgDn scroll;
`T` switches between accepted messages and the latest accepted replacement;
Esc closes it. Opening the panel preserves your input draft. Approval and
settings key readers take priority, and session teardown removes the modal,
cursor ownership and refresh timer.

The panel displays the accepted working conversation, revision, log watermark,
mirror path, file status and latest file-edit receipt in this process. Message
groups follow retained user requests in working-context order; edited summaries
do not retain original turn identities. The token estimate uses serialized JSON
bytes divided by four. It includes tool payloads, excludes the system prompt,
and is not a provider tokenizer or billing count. Images and reasoning blocks
are indicated without expanding their contents; long payload previews are
bounded and the full content remains in the mirror.

The changes view reconstructs the latest eligible accepted replacement from
the session log, including after resume. Shared leading and trailing messages
are collapsed; the changed span is shown as removed and added messages. A
rewrite or reorder is represented by removals/additions. Context reset clears
that comparison, and edits from abandoned turns are excluded.

File changes are marked pending until the context plugin validates them before
a model call. Missing or unreadable files are marked separately. The viewer
never imports edits, repairs the mirror, writes a snapshot, or affects provider
requests. It shows accepted state even when the mirror contains invalid JSON.
Rejection receipts remain visible across later unchanged exports, but receipts
are transient and do not survive restart. As with the context plugin itself,
accepted edits survive restart only when persistence is enabled.

Run `dart pub get`, `dart analyze`, and `dart test` in this directory to verify.
