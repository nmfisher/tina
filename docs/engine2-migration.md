# Engine2 migration status

The root executable now runs engine2. `bin/tina.dart` imports `tina_tui` and the
generated version constant; the root runtime manifest depends only on
`tina_tui`. Legacy source remains for reference and regression tests, with its
dependencies moved to `dev_dependencies`. Import-closure checks prevent the
executable from reaching legacy app/engine, workflows, Attractor or repository indexing. The loop still depends only on `tina_core`, and the host on core
and engine2; concrete packages live under `packages/plugins`.

## Replacement coverage

- Daily agent turns, tool status/live output and subprocess cancellation.
- Optional activity browser with collapsible tool details, edit previews,
  structured errors/recovery and child progress (`tina/activity-tui`).
- FIFO queued input while busy, including unfinished-draft preservation.
- Filesystem/command approvals through a selectable channel plugin; narrow
  terminal layouts and resize preserve modal state.
- Persistence, startup session listing/resume, plans, goals, auto-compaction,
  subagents and opt-in file resources/skills.
- Namespaced plugins, global/workspace/session selection and supported live
  enable/disable operations.
- Custom providers, pools, request scheduling, token admission limits,
  reasoning/output settings, themes and a searchable settings editor.
- Command argument completion, settings-field completion and generated
  bash/zsh/fish flag/path completion.
- Self-update in `tina_self_update`: explicit check/install, checksum and archive
  verification, generic-channel approval, private-bundle ownership checks,
  rollback and cleanup. No update check runs automatically on startup.
- Root `--help`, `--version`, `--configure`, session flags and release builds
  use the same CLI implementation.

See [configuration](engine2-config.md) for exact semantics and limits.
`tina_providers` owns routing/scheduling/budgets; `tina_self_update` owns update
behavior. Neither adds concrete dependencies to the host or loop.

## Cutover and validation

The macOS build script produces a marked private bundle. Linux Docker builds
stamp the same marker. Release CI exercises the actual built executable on a
controlling PTY before packaging each platform's tarball and checksum. It checks
real streamed turns against a local model stub, queued input, cancellation,
approvals, activity browsing/diffs/errors/child progress, settings, scoped
plugins, persistence/resume and terminal restoration.
Regular macOS CI also exercises the launcher symlink layout.

Locally validated: source/root CLI and compiled macOS arm64 bundle at 80×10,
80×24 and 120×30, plus focused package, wire, config, update and architecture
tests. Linux builds are left to CI because the local Docker daemon is unavailable.
No release version was bumped, tag pushed, or release published in this cutover.
A real-provider visual acceptance pass remains useful; the PTY tests are not a
complete visual usability review.

## Remaining work and intentional exclusions

User-input classification is wired through `tina/classification` in
`packages/classification`: intent first, then Git subcommands for instructions.
It reports predictions without routing or permission changes. Repository
classification and indexing remain disconnected pending redesign. Attractor remains available to the
workflow plugin and legacy consumers; the workflow plugin is not loaded by the
new app. The deferred legacy session slash commands have not been ported.
Clarifications use the ordinary conversation, with no separate free-text plugin
question channel.

Old session files can be converted with `--import-sessions`; see the
[import guide](engine2-session-import.md) for dry runs, missing-file handling,
resume IDs and the metadata that remains archival. Legacy app/engine
source, tests and their architecture exceptions can be retired in a separate
cleanup after acceptance. Preserve the existing modified `dart_notcurses`
submodule; it is not part of that deletion.

## Activity presentation

`packages/plugins/tina_activity_tui` owns tool status, streaming output and the
activity browser. It is enabled by default and supports live enable/disable.
F4 or `/activity` opens it, including during a running turn. Enter/Tab folds the
selected call, arrows select, Page Up/Down or the wheel scroll, and Esc/F4 closes.
Browsing preserves the input draft and yields to approval/settings key readers.

The browser retains the latest 80 calls. It shows arguments, bounded live output,
results, elapsed time and child progress. Edit previews compare replacement
arguments; they are not whole-file diffs. Failed/unconfirmed replacements are
explicitly labeled. Structured errors expose their message, recovery guidance
and current context. Replay restores calls/results without executing tools or
reprinting output; transient progress and timing are not persisted.

The application mounts the same generic `ConsoleContribution` used by other UI
plugins. The console provides removable key bindings and modal registration;
it has no activity-specific dispatch. Tools report generic progress through
their execution context, and the subagent plugin emits child status through
that channel. Neither the loop nor the host depends on this UI plugin.

## Approval channels

Approval delivery is now plugin-owned. `packages/plugins/tina_approvals` owns
pending requests and the typed requester/channel contracts;
`packages/plugins/tina_approvals_tui` owns the console dialog and key handling.
`tina_console` exposes generic frontend contribution lifecycle and modal layout
helpers. The application mounts those contributions without knowing their
request types. This avoids a UI-plugin/application import cycle without moving
all application assembly in this change.

The loader resolves declared capabilities before creating plugins. Tools receive
an `ApprovalRequester`; the service receives one configured `ApprovalChannel`.
`[plugins].approval_channel` (also editable in settings) defaults to
`tina/approvals-tui`. An embedding application can register a namespaced stream
or remote channel without changing tools, the loop, or frontend dispatch.
The former `TuiSession.wireApprovers` and direct `TuiAssembly.start(approver:)`
entry points are removed.

Pending approvals expire (five-minute default), deny on turn cancellation,
channel failure or shutdown, and reject duplicate/late replies. The stream
adapter has one subscriber and denies on disconnect. Requests are not persisted;
SMS delivery/authentication remains the responsibility of a future channel
adapter. Sandbox grant policy and the legacy app are unchanged.

## Scoped and live plugin management

Settings → Plugins shows checkboxes, configured/loaded state, source scope and
pending changes. Choose Global (default), Workspace or Session; Space/Enter
toggles, Ctrl-R restores inheritance. Changes save immediately. Workspace config is `<working-directory>/.tina/config`; per-ID
`[plugins.overrides]` inherit the global enabled baseline. Reset removes an
override instead of copying another scope's current value. Session changes do
not write a file. Unknown or invalid selections fail before configuration writes
or live changes.

Activity presentation, plans, goals, compaction and file resources can
attach/detach between turns.
The host and loop track plugin-owned command, executor and subscription
registrations; frontend contributions attach and detach through the generic
console interface. Plans replay from the existing log after re-enable.
Persistence and subagents remain restart-only. Capability dependencies are
validated, and a provider cannot be removed while its consumers still need it.
Provider rebinding is conservatively deferred to restart. New external plugins
must explicitly opt into live lifecycle support.

## Tool execution and cancellation

The loop exposes generic transient `ToolStarted`, `ToolOutput`, `ToolProgress`
and `ToolFinished` events and a per-call cancellation/output/progress context.
Ordinary executors remain supported. The activity plugin consumes these events
without importing a concrete tools plugin; persisted tool results still come
only from the log.
Late output after completion/cancellation is ignored. The renderer caps live
output at 64 Ki characters per call and strips terminal controls. Disabling
`tina/activity-tui` removes tool presentation and its key bindings, while tools
continue executing and recording results normally.

`tina_tools` forwards execution control through its permission and OS sandbox
wrappers. `IoProcessRunner` owns a `Process.start` child, feeds stdin, drains
stdout/stderr while running, and retains up to 1 Mi characters per output stream.
Cancellation and timeout send TERM to the process tree, then KILL surviving
processes after a grace period, before returning the partial output. Cancellation
is distinct from timeout. Tests cover a child that ignores TERM and a subsequent
successful command. Tree cleanup is best effort on POSIX using `pgrep`: already
reparented/double-forked daemons and children created after the snapshot are not
guaranteed to be found. This does not introduce managed background jobs.

The plugin now connects command approvals to the same configured approval
service as filesystem approvals. Remembered command approvals retain literal
argv and working-directory identity rather than treating shell wildcards as
grant patterns. Explicit embedding-supplied patterns remain available.
Process tools use the workspace cwd and follow mode changes; `osSandbox: false`
now actually omits the OS wrapper (permission checks still apply).
