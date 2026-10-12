# Session ownership and behavior baseline

Status: **first preparatory step complete; no production behavior changed**.
Original inventory checked against v0.9.56 on 2026-10-11. The completed
feature splits and disposable attachment observations are recorded in
[the implementation status](daemon_sessions.md#phase-1--extract-independent-feature-views);
rows below retain the original behavior as the compatibility baseline.

This is the inventory for phase 0 of
[daemon sessions](daemon_sessions.md). It records current behavior separately
from proposed ownership. It does not claim that multiple TUI clients work today.
Existing plugin IDs, settings scopes, sandbox policy and SQLite durability remain
part of the compatibility baseline.

## Ownership vocabulary

- **Client:** terminal modes, keyboard/input ownership, drafts, scroll, focus,
  layout, dialogs, selections and feature presentation.
- **Session runtime:** one Host/AgentLoop, active turn, accepted inputs, feature
  state/policies, tools/jobs, provider access, approval authority and persistence.
- **Application/configuration:** persisted global/workspace configuration,
  executable update/restart and starting/listing/selecting sessions. Session
  overrides belong to the session even though they use the same settings API.
- **Mixed:** a client interaction reads or changes runtime/configuration state.
  Split the presentation and mutation; do not relocate both to one side.

The application composition root wires features; it does not take ownership of
their policy decisions or replace their stores. Parent/child sessions may share
a database file while retaining separate plugin instances and connections.

## Command and operation matrix

| Surface | Current implementation/behavior | Intended ownership | Compatibility requirement |
|---|---|---|---|
| Plain input | `TuiSession.runLine` calls `Host.send`; app/panel dispatch offers input while busy. | Client drafts; runtime accepts and executes. | Preserve one loop and current steering, including input guards and tool-result pairing. |
| Busy input | `Host.offerInput` uses the loop's queue, can close an in-flight model call, and rejects submissions outside an eligible active turn. | Runtime queue and turn state. | Do not replace steering with a different FIFO policy or admit slash/shell commands as model input. |
| `/quit` | Assembly sets its quit flag; app/CLI teardown cancels and closes its owned session. | Client exit plus explicit embedded runtime ownership. | Embedded exit still cleans up. A future non-owning attachment must only detach. |
| `/help` and completion | Assembly prints registered commands and keyboard guidance; completion reads command metadata/models/workspace files. | Client presentation; runtime supplies available operations/data. | Disabled/unloaded commands disappear; unknown commands never become model input. |
| `/settings` | Opens a TUI callback; headless reports that the editor requires the TUI. It may open while a turn runs. | Client editor; runtime/configuration mutations. | Preserve scope/inheritance, validation, stale-draft checks and application status. |
| `/model` | Session-controls plugin owns picker and calls host model switch; no-argument headless form lists models. | Client picker/history; runtime selected model/provider. | Switching requires idle; selecting a model does not create a new session or change defaults. |
| `/clear` | Session-controls calls loop history clear; chat reacts to the log marker. | Runtime context mutation; each client redraws. | Preserve append-only history and input recall across clear/resume. |
| `/compact` | Compaction feature summarizes between turns; agent-managed context can disable it. | Runtime feature operation. | Preserve recent messages, persisted summary and context-policy coordination. |
| `/mode`, Shift-Tab | Mode feature changes tools permission policy; TUI shortcut/status presents it. | Client shortcut; session runtime policy. | Preserve read-only/ask/auto behavior and sandbox enforcement. |
| `!command`, `/shell` | Shell feature runs explicit user commands, captures bounded output and owns process cancellation; commands may run while the model is busy. | Runtime job; client command input/output presentation. | Preserve user-shell permissions, isolation from the model queue and descendant cancellation. |
| `/update [check\|install]` | Update feature checks/prepares verified bundles, asks before installation and invokes restart wiring; may run while busy. | Application update lifecycle; runtime approval; client progress. | Preserve verified update and resume ID; do not tie daemon restart to a client's exit later. |
| `/plan` | Empty form reads state; clear/approve/reject/request-approval/done/pending change the plans feature's state through the log. Ctrl+P opens its view. | Runtime feature mutations; client plan view. | Rehydrate state after disable/re-enable; do not confuse plan sign-off with tool permission grants. |
| `/goal` | Status reads; set/clear/check modify or judge the goal; headless goal runner requests turns until completion/bounds. | Runtime goal feature/model access; client presentation. | Preserve goal judgment, explicit turn bounds and provider limits. |
| `/classification` | Base feature reads latest status/categories; console adapter opens status/hierarchy views. | Runtime inference/category state; client viewer. | Detaching a view must not stop classifier work; keep auxiliary model streams out of chat. |
| `/context` | Read-only context viewer toggles during busy turns; accepted context/file edits are owned by the context feature. | Client viewer; runtime context feature. | Opening/closing a viewer does not accept pending edits or write context state. |
| `/activity`, F4 | Activity view projects log/tool activity and shows results/diffs/child progress. | Client projection; runtime observations. | Preserve session attribution and completed tool results. |
| `/spawn`, panel controls | App's `newSession` creates a distinct assembly/Host; panels select, minimize, maximize, resize and retain independent drafts. | Client layout; application/runtime creates sessions. | Today's spawned panels are different sessions, not two attachments to one session. |
| `/close`, Ctrl+X | Panel workspace cancels active work and closes its owned spawned session; focus returns to another panel. | Client closes a view; embedded owner also stops its owned runtime. | Preserve current embedded cleanup while making ownership explicit before remote attachment. |
| Escape, Ctrl+C, SIGINT | Editor interprets keys; session cancellation reaches model/tools and active manual shell commands. CLI SIGINT cancels headless work. | Client key handling; runtime cancellation; process owner handles exit. | Preserve draft clearing versus cancelling/quitting, input usability afterwards and terminal restoration. |
| Permission/confirmation answer | TUI channel gets a ticket; external stream channel correlates by ID; service invalidates answers on cancellation/expiry/shutdown. | Runtime authority; chosen channel/client presents. | Keep fail-closed behavior, single resolution, offered-scope validation and configured delivery authority. |
| Editable approval regex | Client leases model through injected suggester, edits/reviews; approvals validate; tools store scoped rule bound to execution context. | Client draft; future runtime model operation/validation/storage. | Preserve literal fallback, late-edit protection, full-command match, scope restrictions and revocation. |
| Remaining `Terminal.ask` | Buffered terminal pairs answers FIFO and resolves pending questions with empty answers on close. | Runtime identified question; client answer entry. | Record current FIFO limitation; do not add multi-client answers before IDs are introduced. |
| Notices/output | Plugins write to shared `Terminal`; `onLine` routes into chat. | Runtime session observations or client-local command response, depending on origin. | Mixed routing needs an explicit split; do not expose raw process terminal controls. |
| Resume/list/continue/import/configure | CLI reads store/configuration before building the session; resume rebuilds a Host from persisted history. | Application services; client selection/editor. | Restore history, selected model and session overrides; listing/configuring need no running session. |

The matrix covers commands from the shipped first-party catalog and built-in
assembly commands. Tools (including MCP tools) are runtime operations, not
client-local commands. Extension commands remain owned by their registering
plugin. `tina_workflows` has workflow commands/questions but is not in the shipped
catalog; its `Terminal.ask` use still belongs in the interaction migration.

Sources:
[assembly/dispatch](../../packages/tina_tui/lib/src/assembly.dart),
[TUI wrapper](../../packages/tina_tui/lib/src/tui_session.dart),
[app](../../packages/tina_tui/lib/src/app.dart),
[panel session view](../../packages/tina_tui/lib/src/session_view.dart),
[panel workspace](../../packages/plugins/tina_chat_tui/lib/src/panels_tui.dart),
[plugin catalog](../../packages/tina_tui/lib/src/plugin_catalog.dart),
[CLI](../../apps/tina_cli/lib/src/cli.dart).

## Settings and permission matrix

Scopes below are current declared scopes. G = global, W = workspace, S =
session. A setting's application timing does not change because its editor is
moved. Settings definitions default to G/W/S and immediate application unless
their definition overrides that.

| Setting/action | Scope and current timing | Owner/effect to preserve |
|---|---|---|
| `tina/chat-tui/theme` | G; immediate | Persisted client appearance preference; all panels in one terminal share it. |
| `tina/chat-tui/terminal_alerts` | G; immediate | Client terminal attention preference; sibling sessions see saved changes. |
| `tina/session-controls/default_model` | G/W; new session | Configuration default; does not switch a running session. |
| `tina/approvals/channel` | G/W; restart | Runtime delivery selection; exactly one channel, including third-party channels. |
| `<plugin-id>/enabled` | G/W/S; idle for live manifests, otherwise restart | Runtime features and presentation visibility must separate later while retaining IDs, required dependencies and requested-versus-loaded status. Delivery-role plugins use the channel choice instead of an enable toggle. |
| `tina/tools/read_only_directories` | G/W/S; immediate | Tools feature's read grants and live read-only jail layout; never becomes a write grant. |
| `tina/tools/write_directories` | G/W/S; immediate | Tools feature's write grants and live writable jail layout. |
| `tina/tools/home_caches` | G/W/S; immediate; subsequent commands | Synthesized-home/cache layout; credential exclusions remain enforced. |
| `tina/mode/classifier_instruction` | G/W/S; next request | Mode feature's approval-classification preferences; cannot bypass permission or OS enforcement. |
| `tina/providers/<limit>` | G/W/S; next request | Existing conversation/subagent budgets and request limits; do not accidentally share counters across independent sessions. |
| `tina/providers/<provider>/max_output`, `thinking` | G/W/S; next request | Provider generation configuration and inherited values; thinking selection remains one composite choice. |
| `tina/step-limit/max_steps_per_turn` | G/W/S; next request | Step-limit runtime feature; 0 means unlimited. Legacy standalone editor is global-only. |
| `tina/context/budget_tokens`, `response_reserve_tokens` | G/W/S; next request | Context feature; retain cross-field budget validation and current accepted context. |
| `tina/subagents/max_sub_agent_depth`, `max_sub_agent_concurrency` | G/W/S; next request/future spawns | Subagent feature; existing children continue under their current execution context. |
| Provider credentials/model catalog/configuration | Provider editor currently edits global configuration | Configuration/model access; generic client snapshots must not contain credential values. |
| MCP server definitions, command/args/cwd/env/URL/headers/timeout | MCP contribution currently exposes global edits | MCP feature/configuration; preserve disabled-by-default additions and next-message application. Secret fields need explicit editor handling. |
| Remembered command approvals: list/revoke | Session memory, workspace-pinned persistent rules, or global persistent rules | Tools approval store; exact/regex rules retain executable, cwd where applicable, environment, stdin and permission context. |
| Exact file/network/execution approvals | Current session/turn rules defined by tools | Runtime authorization; independent sessions do not inherit each other's ephemeral grants. Two future views of one session share that session's authority. |
| Directory grants from approval offers | Saved through existing scoped directory settings | Runtime tools/settings mutation, with gate and live layout agreement. |

Other specialized plugin settings remain owned by their feature. Plugins may
read configuration independently; this work does not consolidate their reads or
persistence connections.

Sources:
[settings definitions](../../packages/libraries/tina_settings/lib/tina_settings.dart),
[settings catalog](../../packages/tina_tui/lib/src/settings_catalog.dart),
[scoped backend](../../packages/tina_tui/lib/src/scoped_config.dart),
[plugin settings](../../packages/tina_tui/lib/src/plugin_settings.dart),
[settings panel](../../packages/tina_tui/lib/src/settings_panel.dart),
[provider panel](../../packages/tina_tui/lib/src/providers_panel.dart),
[MCP settings view](../../packages/plugins/tina_mcp_tui/lib/src/mcp_view.dart),
[approval store](../../packages/plugins/tina_tools/lib/src/command_approval_store.dart).

## Lifecycle and observation baseline

| Current seam | Current ownership/limitation | Refactor obligation |
|---|---|---|
| `SessionView.detachConsole` | Removes console contributions/listeners and callback bindings, without closing Host. | Preserve view-only detach. It still clears shared callback slots, so this is not yet safe with a second attachment. |
| `SessionView.close`, `TuiSession.close` | Close the owned assembly/runtime; buffered asks resolve empty. | Separate attachment detach from embedded-owner shutdown. |
| `runApp` exit/failure | Cancels work, waits for commands, restores terminal resources, closes session. | Preserve embedded cleanup; do not apply it to non-owning attachments. |
| Panel shutdown/close | Cancels active work; closes owned spawned sessions. | Preserve owner cleanup and distinguish it from client layout disposal. |
| Headless finally/SIGINT | Cancels on interrupt; closes assembly on completion/error. | Remains an explicit runtime owner with unattended approval policy. |
| Log subscribers | Replay then live entries; batch persistence precedes per-entry observers. | Preserve ordering, immutable entries, atomic writes and failure propagation. |
| Live model watch | `TuiSession.runLine` controls assembly's observation marker. | Move observation lifetime to runtime; do not render auxiliary providers as session output. |
| Single UI callbacks | Settings/watch/output/plugin-manager callbacks can be overwritten. | Replace with independently disposable subscriptions. |
| External stream approvals | Channel subscriber owns delivery; unsubscribe denies requests. | UI detach must not unsubscribe an unrelated external delivery owner. |
| TUI approvals | Detaching its channel denies pending requests today. | Keep current fail-closed behavior until broker ownership/policy is explicitly migrated. |
| Store | Each persistence plugin owns its connection; FULL transactions, append-only rows and sequence checks. | Keep durability and plugin ownership; database locking is not exclusive live-session ownership. |

## Existing coverage to retain

| Behavior | Existing coverage |
|---|---|
| Busy input, stalled streams, tool pairing and input guards | [steering_test](../../packages/tina_engine_2/test/steering_test.dart), [panels_test](../../packages/tina_tui/test/panels_test.dart) |
| Dispatch, immediate shell/context/update, shell cancellation | [tui_session_test](../../packages/tina_tui/test/tui_session_test.dart) |
| Drafts, focus, scroll, spawned-session attribution and panel close | [panels_test](../../packages/tina_tui/test/panels_test.dart) |
| Draft clear, Ctrl+C, Escape, settings during requests | [turn_rendering_test](../../packages/tina_tui/test/turn_rendering_test.dart) |
| Headless prompt/goal bounds, model override, continue, unattended denial | [headless_test](../../apps/tina_cli/test/headless_test.dart) |
| Resume transcript/input history and terminal restart | [assembly_store_test](../../packages/tina_tui/test/assembly_store_test.dart), [resume_input_history_test](../../packages/tina_tui/test/resume_input_history_test.dart), [restart_terminal_test](../../apps/tina_cli/test/restart_terminal_test.dart) |
| Model switch, clear and manual compaction | [conversation_controls_test](../../packages/tina_tui/test/conversation_controls_test.dart) |
| Settings inheritance, atomic edits, stale drafts and session snapshots | [scoped_settings_test](../../packages/tina_tui/test/scoped_settings_test.dart), [config_batch_test](../../packages/tina_tui/test/config_batch_test.dart) |
| Live plugin changes, dependency validation and restart-only features | [scoped_plugins_test](../../packages/tina_tui/test/scoped_plugins_test.dart), [live_plugin_ui_test](../../packages/tina_tui/test/live_plugin_ui_test.dart) |
| Provider/configuration hot reload and next-request settings | [provider_reload_test](../../packages/tina_tui/test/provider_reload_test.dart), [generation_reload_test](../../packages/tina_tui/test/generation_reload_test.dart) |
| Approval correlation, scope validation, cancellation and disconnect | [approvals_test](../../packages/plugins/tina_approvals/test/approvals_test.dart), [approval_channel_test](../../packages/tina_tui/test/approval_channel_test.dart) |
| Ephemeral grant isolation and late-approval rejection | [approval_grants_test](../../packages/tina_tui/test/approval_grants_test.dart) |
| Regex confirmation/edit preservation and scope/context matching | [command_pattern_review_test](../../packages/plugins/tina_approvals_tui/test/command_pattern_review_test.dart), [command_approval_store_test](../../packages/plugins/tina_tools/test/command_approval_store_test.dart) |
| Sandbox HOME/caches/config/credential exclusions and live grants | [sandbox_home_test](../../packages/plugins/tina_tools/test/sandbox_home_test.dart), [live_os_sandbox_test](../../packages/plugins/tina_tools/test/live_os_sandbox_test.dart) |
| Detached child-process argv/environment/cwd/pipes/cancellation | [process_launcher_test](../../apps/tina_cli/test/process_launcher_test.dart), [shell_terminal_test](../../apps/tina_cli/test/shell_terminal_test.dart) |
| Persistence/resume/failure, log batch ordering and FULL per connection | [host_store_test](../../packages/plugins/tina_persistence/test/host_store_test.dart), [store_test](../../packages/plugins/tina_persistence/test/store_test.dart), [log_batch_test](../../packages/tina_engine_2/test/log_batch_test.dart), [database_test](../../packages/tina_sqlite/test/database_test.dart) |

The suite map identifies existing protection; it does not imply that all future
multi-client cases are already covered. Native PTY/backend smoke checks remain
required when runtime/input/teardown implementation changes, but this phase adds
no production changes and does not rerun those separately.

## Added characterization coverage

[session_view_lifecycle_test](../../packages/tina_tui/test/session_view_lifecycle_test.dart)
fills two uncovered boundaries:

1. Detach a view while a model stream is active, steer input while detached,
   complete the turn, verify the live store matches the loop, then attach a
   replacement console and verify it renders the retained history.
2. Detach a view while a third-party channel holds a write approval. Verify the
   request stays pending and no write occurs before an external answer; then
   verify the correlated answer completes the write and duplicate answers fail.

These tests pin useful behavior that already exists. They do not lock in the
shared-callback limitation, FIFO question routing or cancellation on the exit of
a future non-owning client.

## Validation

The phase-0 baseline runs the full `tina_tui/test` directory, steering/log-batch
tests, approval runtime/TUI suites, affected chat adapters, persistence/store/
SQLite tests and tools' command-approval/home/live-sandbox suites. Live provider
and PTY-tagged tests are excluded; local HTTP stubs and ordinary OS sandbox tests
remain included. The repository SDK is the one specified in `AGENTS.local.md`.

Validation completed:

- Baseline suites: **544 passed, 1 platform-specific skip**.
- Corrected lifecycle tests plus all architecture checks: **45 passed**.
- Dart analysis: no issues. New test formatting and whitespace checks passed.
- Local documentation links resolve.

Test output: `/private/tmp/tina-session-ownership-baseline-tests.log` and
`/private/tmp/tina-session-ownership-final-checks.log`. No production source,
dependency manifest, configuration schema or database schema changed.
