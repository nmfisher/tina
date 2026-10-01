# Console presentation

`tina/chat-tui` owns the interactive transcript and model prompt. It uses the
legacy Markdown, transcript and timestamp renderers; the old application's
imports now re-export the same implementation. `tina/mode-tui`, in this package,
owns Shift-Tab and the mode strip. Both are enabled by default and can be toggled
in Settings → Plugins at session, workspace or global scope.

- Chat rows have `HH:mm:ss` on the first line of each block. Recorded timestamps
  survive replay and resizing; imported messages without timestamps use the time
  they are first displayed, as the old renderer did.
- The prompt is the model name, with the old busy spinner and unread-row badge.
- User, Markdown, reasoning, tool and notice rows use the old themes and layout.
  Tools show `→ name · arguments`, followed by `ok`/`failed` and measured timing.
- Reasoning and tool output start collapsed. Ctrl-B selects foldable blocks;
  arrows select, Enter/space folds, Escape/Ctrl-B leaves. Drafts stay intact.
  Page Up/Down and the mouse wheel scroll the transcript without editing input.
  F4's activity browser remains available for full result details and edit diffs.
- The status strip carries the mode, plan, goal, session ID and reported token
  spend, including the configured session cap. Unknown failed/cancelled request
  spend appears separately as `+~N est`; measured plus estimated spend controls
  the percentage, warning colors and `SPEND LIMIT TRIPPED`. Under width pressure it drops
  optional left-side information before the token counter.

`tina/update-tui` is also enabled by default. It consumes the channel-independent
status capability from `tina/update`, starts one cache-aware background check,
and always shows the running version (`vX.Y.Z`), followed by
`update ⬆ vX.Y.Z · /update` when a newer release is available. Checking, failed,
and deferred checks are visible; up-to-date shows just the running version.
The version remains visible when background checks are disabled or fail.
The version and update indicators have
priority over optional plan/goal/session text, while the token counter retains
the right-hand slot. `ConsoleContext.bindStatus` gives each plugin ownership of
its own lines, so unloading one does not erase the others. Unchecking
`tina/update-tui` in Settings → Plugins removes the view live. `COCOON_UPDATE_CHECK=0` suppresses automatic
checks; explicit `/update` checks still work and update the same status.

The plugin subscribes to the loop's log and tool activity. Provider adapters send
transient `WatchObserver` events; final log entries reconcile streamed drafts.
Reasoning, completion state and provider signatures are retained by the loop;
partial or unsigned thoughts stay local instead of entering Anthropic requests.
The host does not import this package. The frontend mounts generic
`ConsoleContribution`s and routes text notices through `ConsoleTranscript`.
`ConsoleContext` supplies scoped shortcuts and a live prompt binding. Approval
readers and modal surfaces retain keyboard priority.

The `tina/plans` console attachment is a read-only progress list. Focus it with
Ctrl-G, Tab, Enter; Up/Down selects an item, Right expands its summary and
subtasks, Left collapses, and Enter/Space toggles. Page Up/Down or the mouse
wheel scrolls long summaries. Escape returns to the chat draft; Ctrl-P hides
the panel. Browsing never approves/rejects a plan or changes item progress.
The plan tool stores short titles and separate summaries in session state, so
they survive resume. Older items without summaries still expand their full text.

`tina/panels-tui` supplies `/spawn [provider/model]`, `/panels` and `/close`.
It manages frames, focus, drafts, histories and per-panel submission queues
through generic console session views; the application supplies session creation
and execution. The engine loop has no panel or focus concepts. Ctrl-G/Ctrl-W
enters navigation, arrows/Tab select and Enter focuses. Ctrl-X closes a panel;
Ctrl-O toggles full width. Two panels fit side by side at 100 columns or wider;
other panels remain reachable through the focus ring. Approvals serialize across
views and hold focus on the requesting panel until answered. This plugin is
enabled by default; changing its enabled state requires a restart.

The mode shortcut and `/mode` share `ModeControl`, whose setter updates both the
file sandbox and process runner. Shift-Tab switches **normal ↔ read-only** without
submitting input, cancelling a turn, or adding chat rows. It affects subsequent
tool checks; it does not retroactively stop an already running tool. This change
does not introduce the legacy four-mode permission policy.

If an existing config explicitly lists enabled plugins, add `tina/chat-tui`,
`tina/mode-tui`, `tina/panels-tui`, `tina/update` and `tina/update-tui` to enable these views. Disabling chat presentation
removes its transcript and prompt contribution; it does not change execution or
persistence. Headless replies continue to use the ordinary terminal sink.

Validation: `dart test` covers the legacy Markdown/layout expectations, timestamp
stability, narrow widths, keyboard ownership, replay, streaming reconciliation,
repeated call IDs and output bounds. `tool/smoke_engine2.py` drives the root CLI
on a PTY against a local model stub, including Shift-Tab and tool inspection.
