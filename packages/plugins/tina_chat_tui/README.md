# Console presentation

`tina/chat-tui` owns the interactive transcript and model prompt. It uses the
legacy Markdown, transcript and timestamp renderers; the old application's
imports now re-export the same implementation. `tina/mode-tui`, in this package,
owns Shift-Tab and the mode strip. Both are enabled by default and can be toggled
with `/plugins` at session, workspace or global scope.

- Chat rows have `HH:mm:ss` on the first line of each block. Recorded timestamps
  survive replay and resizing; imported messages without timestamps use the time
  they are first displayed, as the old renderer did.
- The prompt is the model name, with the old busy spinner and unread-row badge.
- User, Markdown, reasoning, tool and notice rows use the old themes and layout.
  Tools show `→ name · arguments`, followed by `ok`/`failed` and measured timing.
- Reasoning and tool output start collapsed. Ctrl-B selects foldable blocks;
  arrows select, Enter/space folds, Escape/Ctrl-B leaves. Drafts stay intact.
  F4's activity browser remains available for full result details and edit diffs.
- The status strip carries the mode, plan, goal, session ID and reported token
  spend, including the configured session cap. Under width pressure it drops
  optional left-side information before the token counter.

The plugin subscribes to the loop's log and tool activity. Provider adapters send
transient `WatchObserver` events; final log entries reconcile streamed drafts.
The host does not import this package. The frontend mounts generic
`ConsoleContribution`s and routes text notices through `ConsoleTranscript`.
`ConsoleContext` supplies scoped shortcuts and a live prompt binding. Approval
readers and modal surfaces retain keyboard priority.

The mode shortcut and `/mode` share `ModeControl`, whose setter updates both the
file sandbox and process runner. Shift-Tab switches **normal ↔ read-only** without
submitting input, cancelling a turn, or adding chat rows. It affects subsequent
tool checks; it does not retroactively stop an already running tool. This change
does not introduce the legacy four-mode permission policy.

If an existing config explicitly lists enabled plugins, add `tina/chat-tui` and
`tina/mode-tui` to that list to enable these views. Disabling chat presentation
removes its transcript and prompt contribution; it does not change execution or
persistence. Headless replies continue to use the ordinary terminal sink.

Validation: `dart test` covers the legacy Markdown/layout expectations, timestamp
stability, narrow widths, keyboard ownership, replay, streaming reconciliation,
repeated call IDs and output bounds. `tool/smoke_engine2.py` drives the root CLI
on a PTY against a local model stub, including Shift-Tab and tool inspection.
