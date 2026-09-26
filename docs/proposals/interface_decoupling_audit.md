# Interface decoupling audit — can a non-TUI front end host tina?

- **Status:** Proposal (not shipped)
- **Owner:** unassigned
- **Created:** 2026-09-26
- **Suggests tickets:** tin-7b7k (process-seam extraction), tin-7c2d
  (audit the asker/inventory against a second front end)

## Summary

**Question.** The architecture review asked whether an interface outside the
terminal — web, Signal, Telegram, WhatsApp — could attach to tina without
rewriting the core. This audit walks every seam a second front end must cross
and answers: **the core is closer than the fear suggests, but three gaps are
real** — (a) every human-input surface outside the main TUI conversation is
*TUI-shaped* (key reads, overlays, editors), so a second front end inherits
"null in headless" stubs where it should inherit contracts; (b) two gates
auto-answer (`HeadlessInterviewer` auto-yes, `AskUserTool` auto-first-option),
so a second front end that naively reuses the headless path answers its own
questions; (c) nothing persists an open ask, so an answer arriving after the
process exits is dropped. None of these requires redesign — they are the same
three facts the remote-answerable-approvals review
(`docs/proposals/remote_answerable_approvals.md`) found from the approvals
side; this audit reaches them from the front-end side and adds the
terminal/PTY placement findings that determine how much of the engine a
non-terminal host must carry.

**Verdict per front end.**

| Front end | Blocking gaps | Effort after tin-3i3l steps 1–3 | Verdict |
|---|---|---|---|
| Web (HTTP/WS, local or remote) | ask durability + ingress; no `HttpServer` anywhere in prod code today | Medium — `tina serve` = one `HostInterface` impl + transport | **Feasible** |
| Signal / Telegram / WhatsApp bot | same, plus async answer latency (a bot reply can be minutes later) | Medium — same daemon, bot API instead of HTTP | **Feasible**, gated on ask records surviving the wait |
| WebAssembly in a browser tab | `dart:io` throughout the engine (44 files), FFI PTY, `Process.run` tools | Large — a different port, not a front end | **Not this seam** |
| Cloudflare Workers (edge) | wasm constraints; spike exists (`spikes/dart_wasm_worker`) | Large | **Not this seam** — spike verdict: "it runs", but no `dart:io` |

The first two rows are the same daemon with different transports. The last
two are not front ends in the sense this audit means — they are re-platforms,
and the review says so rather than pretending a seam exists.

**Recommendation.** Land the three already-proposed approval steps (durable
ask store, `/approve`-style commands, answerability in posture), then build
`tina serve` as a `HostInterface` implementation. A second
front end should reuse `CommandRegistry.dispatch` + `InputRoutes` and provide
its own `FrontendCapabilities`; it must not be wired through the TUI
coordinator. One engine-side cleanup (the PTY stack and process registry)
reduces what a non-terminal host must carry. Revised 2026-09-26 after an
external design review: the ordering above is provenance and unattended
defaults first, then a narrow remote host on the existing async interfaces,
then durable records, then suspension/resume if the live host shows it is
needed; the PTY packaging stays a separate cleanup. The review also
corrected four claims in these two documents — the audit's own log is at
"Corrections after external review" at the end of this file.

## Interface inventory — every surface a front end touches

All anchors verified against the working tree on 2026-09-26.

| # | Surface | Location | Shape | Non-TUI reusable today? |
|---|---|---|---|---|
| 1 | Agent output/events | `packages/tina_engine/lib/src/agent/agent_sink.dart:19` (`AgentSink`), `packages/tina_engine/lib/src/agent/agent_event_bus.dart:70` (`AgentEventBus`) | Interface + broadcast stream | **Yes** — headless already drives both; the bus was built for "non-rendering consumers — logging, …" (`packages/tina_engine/lib/src/agent/agent_event_bus.dart:7`) |
| 2 | Host contract | `packages/tina_engine/lib/src/host/host_interface.dart:14` (`HostInterface`) | ~12-method interface; explicitly "without depending on any terminal type" | **Yes** — 3 impls already: `HeadlessHost` (engine), `InvocationHost` (engine), `TuiConversationHost` (root, `lib/host/tui_conversation_host.dart:33`) |
| 3 | Permission asking | `packages/tina_engine/lib/src/permissions/prompt.dart:306` (`typedef PermissionAsker`) | Plain function type | **Yes as a seam; no as wiring** — every interactive asker is built inside the TUI coordinator or its run panels (`lib/pipeline/workflow_permission_asker.dart:1` imports `tina_console`) |
| 4 | Human questions (workflow gates) | `lib/pipeline/tina_interviewer.dart:20` (`TinaInterviewer`) | Attractor `Interviewer` impl; key-capture modal | **No** — TUI-only; headless delegates to auto-approving `HeadlessInterviewer` (`lib/pipeline/tina_interviewer.dart:14`) |
| 5 | Human questions (agent tool) | `packages/tina_app/lib/src/workflows/ask_user_tool.dart:83` | Auto-selects first option when `_ask == null` | **No** — null asker = auto-answer (fail-open) |
| 6 | Turn admission/queue | `packages/tina_app/lib/src/execution/turn_executor.dart:30` (`TurnExecutor`), `:84` (`submit`) | Pure Dart, no I/O | **Yes** — the TUI coordinator drives it; nothing terminal-shaped in the executor itself |
| 7 | Input pipeline/plugins | `packages/tina_app/lib/src/execution/input_routes.dart:175` (`InputRoutes`) | Plugin-scope based; strings in/out | **Yes** — `InputContext` carries `String text` (`packages/tina_app/lib/src/execution/input_routes.dart:15`), not key events |
| 8 | Slash commands | `packages/tina_app/lib/src/commands/command_registry.dart:139` (`dispatch`) | Takes `HostInterface` — no UI types | **Yes, by design** — headless mounts the same contributions (`lib/session_commands/headless_commands.dart:6-8`: "Headless built-ins use the same command contributions … UI-only commands are not mounted in this frontend") |
| 9 | Command capabilities | `packages/tina_app/lib/src/commands/command_context.dart:51` (`CommandContext`), `packages/tina_app/lib/src/commands/command_capabilities.dart` (9 capability interfaces) | Interface aggregate over `SessionController` | **Partly** — the interface is the right shape; 12 members are "null in headless" (`packages/tina_app/lib/src/commands/command_context.dart` — 13 occurrences; `lib/session_controller.dart` — 12) because only the TUI wires them |
| 10 | Frontend capabilities | `packages/tina_app/lib/src/commands/command_capabilities.dart:20` (`FrontendCapabilities`) | `openSettings`/`openPrompts`/… all nullable | **Yes** — a second front end supplies its own; today only the TUI does |
| 11 | Session persistence | `packages/tina_engine/lib/src/persistence/session_store.dart:366` (`SessionStore`), `packages/tina_engine/lib/src/persistence/session_index.dart:17` (`SessionIndex`) | Narrow interface; JSONL impl; read-only startup view | **Yes** — `SessionIndex` exists precisely for pre-runtime reads (SP2, `1e7e252`) |
| 12 | Session exclusivity | `packages/tina_engine/lib/src/persistence/session_lock.dart:9` (advisory cross-process lock) | PID-liveness `.lock` file | **Shared-host hazard** — a daemon holding a session lock excludes every other front end for that session; must be a documented decision, not an accident |
| 13 | Config | `packages/tina_app/lib/src/config/runtime_config.dart:4` ("independent of parsing, persistence and terminal UI") | Immutable value object | **Yes** — the boundary test pins it (`packages/tina_app/test/config/runtime_boundary_test.dart:84`: no `tina_console`/`dart_notcurses`/`args`/`toml`) |
| 14 | Provider layer | `packages/tina_engine/lib/src/llm/*` + `ProviderRegistry` | Interface (`LlmProvider`), HTTP transports | **Yes** — already abstracted for `--provider`/model swaps |
| 15 | PTY / shell panel | `packages/tina_engine/lib/src/terminal/pty_runner.dart:87` | FFI + worker isolate + C shim | **N/A for remote** — a remote front end cannot share a local PTY; the panel is a TUI feature |
| 16 | Terminal packages | `tool/architecture/policy.json:16` (`terminalPackages`: `tina_console`, `dart_notcurses`) | Policy: non-terminal packages may not reach them | **Yes** — the rule holds; the engine is import-clean |

## Findings

### Finding 1 — The core seams are real and already double-implemented

**Proposal.** The engine's front-end contract is `HostInterface`
(`packages/tina_engine/lib/src/host/host_interface.dart:14`), and it is not a paper interface: the engine ships
two implementations of it (`HeadlessHost` `packages/tina_engine/lib/src/host/headless_host.dart:22`,
`InvocationHost` `packages/tina_engine/lib/src/host/invocation_host.dart:10`), the root ships the TUI one
(`lib/host/tui_conversation_host.dart:33`), the app layer ships a null host
(`packages/tina_app/lib/src/session/conversation.dart:157`), and tests ship fakes. Output is equally double-cut:
`AgentSink` for rendering hosts, `AgentEventBus` (`packages/tina_engine/lib/src/agent/agent_event_bus.dart:76`
`Stream<AgentEvent>`) for non-rendering consumers. Slash commands dispatch
through a registry whose `dispatch` signature takes `HostInterface` — no UI
types (`packages/tina_app/lib/src/commands/command_registry.dart:139-145`) — and the headless path mounts the
same command contributions by design (`lib/session_commands/headless_commands.dart:6-8`).

This is the single most important fact for the audit: **a second front end
does not need to rewrite the core.** It implements `HostInterface` +
`AgentSink`, supplies a `PermissionAsker`, mounts commands, and drives
`TurnExecutor.submit` with strings. Every one of those types is in the engine
or app layer and terminal-free.

**Cost.** None for the seam itself — this finding is the reason the effort
estimates above are "Medium" rather than "Large". It is not the whole cost:
the seams do not cover everything a remote front end must build. `ask_user`
speaks `Question`/`Answer` through the attractor `Interviewer`
(`packages/attractor/lib/src/interviewer.dart:31,57,90-91`), not
`PermissionAsker`; plan approvals are persisted `requested` state in
`PlanStore` (`packages/tina_app/lib/src/plans/plan_store.dart:169`) whose
waiting is model guidance in the `update_plan` description
(`plan_plugin.dart:161-170`), not a suspended permission call; and the
transport itself needs serialization, routing, cancellation, and reconnect
behavior on top. One adapter per seam, then the protocol work — the seams
remove the rewrite, not the protocol.

### Finding 2 — Every interactive asker is TUI-shaped; null asker = auto-answer

**Proposal.** The seam exists (`PermissionAsker`, `packages/tina_engine/lib/src/permissions/prompt.dart:306` — a plain
`Future<PermissionResponse> Function(PermissionPrompt)`), but the wiring is
one-sided. The interactive askers — `TuiConversationHost.askPermission`
(via `runPermissionApproval`, a modal), `WorkflowPermissionAsker`
(`lib/pipeline/workflow_permission_asker.dart:1` — imports `tina_console`, captures `y/n/a/d`
through the shared `LineEditor`), `TinaInterviewer` (overlay modals) — all live
in the root package and all read a keyboard. When no asker is provided:

- Workflow gates: `HeadlessInterviewer` **auto-approves**
  (`lib/pipeline/tina_interviewer.dart:14`: "When [screen] or [editor] is null (headless
  mode), it auto-approves").
- `ask_user` tool: **auto-selects the first option** of every question and
  appends an honest note (`packages/tina_app/lib/src/workflows/ask_user_tool.dart:83-90`).
- Permission asks on a background conversation: auto-deny with `decidedBy:
  'background'` (`lib/host/tui_conversation_host.dart:257-267`).

So the two failure modes a second front end must not inherit are both live:
fail-open gates (auto-yes / auto-first-option) and mis-attributed denials
(`decidedBy` defaults to `'user'`, `packages/tina_engine/lib/src/permissions/prompt.dart:290` — the scheduler's
auto-deny asker therefore records user denials).

**Cost.** This is exactly `docs/proposals/remote_answerable_approvals.md`'s territory; this
audit adds only the front-end consequence: **a web/bot front end cannot be
built on the headless path**, because the headless path answers its own
questions. It must supply askers that park the ask and wait — which needs
Finding 4's durable ask store first.

### Finding 3 — The command layer is front-end-ready; the controller wiring is not

**Proposal.** `CommandContext` (`packages/tina_app/lib/src/commands/command_context.dart:51`) is an interface
aggregate of nine capability interfaces (`packages/tina_app/lib/src/commands/command_capabilities.dart:10-73`),
built precisely so "handlers live in their own module and be exercised against
a fake, without standing up the input loop or a host"
(`packages/tina_app/lib/src/commands/command_context.dart:45-47`). `FrontendCapabilities`
(`packages/tina_app/lib/src/commands/command_capabilities.dart:20`) is the overlay surface — every member
nullable, so a front end with no overlays supplies nulls and the commands
degrade, not crash.

But the nulls are pervasive because only one implementation wires them:
`lib/session_controller.dart` alone carries 12 "Wired by the TUI coordinator;
null in headless" fields (`lib/session_controller.dart:43,47,76,81,85,94,98,103,107,121,126,214`),
and `packages/tina_app/lib/src/commands/command_context.dart` documents 13. A second front end implementing
`CommandContext` would start from a wall of optional callbacks with TUI-shaped
semantics (`foldTranscript`'s `('list'|'show'|'hide', n)` verb protocol,
`openImage(path)` taking a local filesystem path, `detachTmux`).

**Cost.** Medium. The fix is not new architecture — it is a second
implementation of the capabilities that a remote front end can actually offer
(`openModelPicker` → a list reply, `confirm` → an ask record), plus honest
"unsupported on this front end" for the rest. The interface already supports
this; nobody has done it.

### Finding 4 — Open asks do not survive the process; answers arrive as new sessions

**Proposal.** A bot front end's defining constraint is latency: the human may
answer an approval in thirty seconds or three hours. Today nothing holds an
open ask: `PermissionAsker` is an in-memory function, the agent turn stays in
flight across `askPermission` (`packages/tina_engine/lib/src/host/host_interface.dart:76`), and when the process
exits the ask is gone. The session lock (`packages/tina_engine/lib/src/persistence/session_lock.dart:9`) is advisory
and PID-based — a dead holder's lock is reclaimed, so a *restarted* front end
can resume the session, but the in-flight turn is not resumed as an ask; it
resumes as history.

This is the third gap the approvals review identified (its Part 4: a durable
ask record + store is "**New**"). From the front-end side it is the same
finding seen from the other side: without persisted asks, a bot front end must
keep a process alive per open question — the exact anti-pattern the daemon
recipe avoids.

**Cost.** Owned by `docs/proposals/remote_answerable_approvals.md` steps 1–3. This audit
depends on it; it does not re-specify it.

### Finding 5 — Engine terminal placement: a PTY stack with no consumer, and build deps that ride along

**Proposal.** The engine is import-clean toward the terminal packages (the
policy checker enforces it; `dart run tool/check_architecture.dart` → "912
owned files; 27 exact exceptions"). But the engine *hosts* a self-contained
PTY stack — vendored C shim (`packages/tina_engine/native/src/pty_shim.c`, 535 lines), FFI bindings
(`packages/tina_engine/lib/src/terminal/pty_shim_bindings.dart:12`), worker-isolate runner (`packages/tina_engine/lib/src/terminal/pty_runner.dart:87`),
38 passing tests — landed 2026-09-16 (`a3f008e`, tin-k7f2) for the interactive
shell panel. **No consumer exists**: zero imports outside its own directory;
not exported from the engine barrel; its only documented use is an example that
imports it by internal `src/` path (`docs/features/pty_backend.md:25`). The
intended consumer (`TerminalPanelController`) is specced for the root package
(`docs/features/terminal_panel_plan.md:45`) — i.e. root → engine-src, the
shape the policy has to exempt.

Two consequences for a non-terminal front end:

- Every engine consumer compiles the C shim's build hook
  (`packages/tina_engine/hook/build.dart:30`), and the three build-time-only deps — `code_assets`,
  `hooks`, `native_toolchain_c` — sit in the engine's `dependencies`
  (`packages/tina_engine/pubspec.yaml:11-14`), landing in every consumer's
  lockfile (`pubspec.lock:82`, `packages/tina_app/pubspec.lock:66`). A wasm or
  browser front end inherits native-toolchain weight for a PTY it cannot have.
- The PTY runner depends on the engine's process registry
  (`packages/tina_engine/lib/src/terminal/pty_runner.dart:14`;
  `ChildProcessRegistry` at `packages/tina_engine/lib/src/tools/process_registry.dart:16`) — host-lifecycle
  machinery (reap-on-exit, `reapAll` from root's exit funnel) that is not
  terminal-specific and not engine-specific either.

**Cost.** Small, and mostly deferred. Do not extract the PTY stack now — there
is no consumer; extraction is justified when the panel lands (either a
recorded baseline exception for the root→engine-src edge, or a `tina_pty`
package, which the one-way dependency arrow already suggests). Do extract
`packages/tina_engine/lib/src/tools/process_registry.dart` +
`packages/tina_engine/lib/src/tools/process_tree.dart` into a small `tina_process`
package (two files; consumers: the engine's process runner, the PTY runner, and
root's exit funnel) — opportunistic, alongside either the PTY move or the first
daemon work, since a daemon is a second process-owning host. All of this must
keep `dart run tool/check_architecture.dart` and `dart test test/architecture/`
green (they pass today: 912 files / 27 exceptions; 22 tests).

**Correction on the build deps (2026-09-26, external review).** This
finding previously recommended moving `code_assets`/`hooks`/
`native_toolchain_c` to `dev_dependencies` as "the cheapest hygiene fix
in this document". That was wrong while the hook stays in the engine.
Dart's rule: a package imported from anything outside `test`/`example`
must be a regular dependency — and these three are imported by
`hook/build.dart` (`packages/tina_engine/hook/build.dart:8-10`), which
every consumer *executes* when it builds the engine. In a consumer's
resolution this package's dev dependencies are ignored (dart.dev,
"Dependencies > Dev dependencies"), so the move could break downstream
builds. The lockfile weight is real, but the only clean way to remove
it is to **extract the PTY stack together with its hook and these three
dependencies into a separate package** — no dependency-entry move can
do it. Supersedes recommendation 4 in tin-7b7k and acceptance item 5
below.

### Finding 6 — The wasm/browser paths are re-platforms, not front ends

**Proposal.** The engine imports `dart:io` in 44 files and `dart:ffi`/`package:ffi`
in its PTY layer; the app layer imports `dart:io` in 27. A browser front end is
therefore not "another `HostInterface` implementation" — it is a port of the
engine to a different I/O substrate. The repo already knows this: the
`spikes/dart_wasm_worker` spike proved a Dart fetch handler can run under
workerd ("**Verdict: it runs.**") but with hard constraints (no runtime wasm
compilation; a single static module; sync-shim async). Nothing in this audit's
seam inventory survives that translation except the pure types (`Message`,
`PermissionResponse`, `InputContext`).

**Cost.** Out of scope for interface decoupling. Recorded so the verdict table
can say "not this seam" honestly instead of omitting the rows.

## Recommendation summary

| # | Recommendation | Status | Cost | Unblocks |
|---|---|---|---|---|
| 1 | Build `tina serve` as a `HostInterface` + asker-parking host, per `docs/proposals/remote_answerable_approvals.md` Part 3 | Proposal (owned there) | Medium | Web + bot front ends |
| 2 | Land provenance + unattended-default fixes first (tin-3i3l steps 1+5); then a narrow remote host on the existing async interfaces; durable ask store, `/approve`-family commands and answerability-in-posture follow (tin-3i3l steps 2–4, revised order) | Proposal (tin-3i3l, revised 2026-09-26) | Small–medium | Every async-answer front end |
| 3 | Second front end = new `CommandContext`/capabilities impl + `InputRoutes` reuse; never wired through `TuiCoordinator` | Proposal | Medium | Clean coexistence of TUI and remote |
| 4 | Extract `process_registry`+`process_tree` → `tina_process`; park PTY (baseline exception or `tina_pty` at panel time). Build deps: keep in `dependencies` while the hook is here; only extracting PTY + hook + deps together removes them from consumers' lockfiles | Proposal (tin-7b7k, revised) | Small | Leaner non-terminal hosts; daemon process ownership |
| 5 | Treat the session lock as a front-end policy decision (one live front end per session, documented) | Proposal | Trivial (docs) | Multi-front-end expectations |
| 6 | Do not pursue wasm/browser as a "front end"; keep it a separate track with its own gates | Standing | None | Honesty in the roadmap |

## Acceptance criteria

1. A `tina serve` process can host a conversation with no `tina_console`/
   `dart_notcurses` import in its closure — verified the same way the persisted
   config is pinned today (`test/architecture/import_boundary_test.dart:109`).
2. An ask *record* issued in a served session survives restart and its
   answer lands on the stored record (audit line, `decidedBy: 'user'`,
   ask id). Resuming the paused tool call itself is *not* claimed — see
   the correction of record in `remote_answerable_approvals.md`
   recommendation 2: on today's executor a denial completes the tool
   result (`tool_executor.dart:620-649`), and suspension/resume is
   separate future work.
3. A gate (`hexagon`) and an `ask_user` in a served session park rather than
   auto-approve/auto-select; the audit record names the front end, never
   `'user'`, for machine-chosen answers.
4. `/help`, `/sessions`, `/model`, `/permissions` dispatch identically from a
   served front end and the TUI (same `CommandRegistry` contributions); UI-only
   commands report "not available on this front end" instead of no-op.
5. ~~After Recommendation 4: `packages/tina_engine/pubspec.yaml`
   `dependencies` contains no `code_assets`/`hooks`/`native_toolchain_c`.~~
   Withdrawn 2026-09-26 (external review): with the build hook in the
   engine, these must stay regular dependencies — consumers execute
   `hook/build.dart`, and dev dependencies are ignored in a consumer's
   resolution. Replacement criterion: if and when the PTY stack is
   extracted together with its hook and deps, the *remaining* engine
   package's `dependencies` drops them — and
   `dart run tool/check_architecture.dart` + `dart test
   test/architecture/` remain green throughout.
6. Nothing in this audit changes `terminalPackages`, the engine barrel, or any
   public engine API.

## Rejected alternatives

- **Build the web front end on the headless path.** Rejected: the headless
  path auto-answers both gate kinds (Finding 2) and would silently approve a
  remote session's own questions.
- **Make `TuiCoordinator` multi-front-end.** Rejected: the coordinator is
  3,021 lines of terminal orchestration (`lib/tui_coordinator.dart`); bending
  it to serve transports couples the newest front end to the oldest
  assumptions. The `CommandContext` interface exists so this is unnecessary.
- **Extract the PTY stack into its own package now.** Rejected: no consumer;
  the only import anywhere is a doc example. Revisit when the terminal panel
  lands — at that point extraction (or a recorded exception) is cheap either way.
- **Persist asks inside `SessionStore` as ordinary messages.** Rejected here
  as a design choice for the approvals proposal to settle; this audit only
  requires durability, not a specific store.
- **Wait for a general "frontend abstraction" layer.** Rejected: `HostInterface`
  + `AgentSink`/`AgentEventBus` + `CommandContext` already are that layer, and
  they are shaped by two live implementations rather than speculation. A third
  implementation will teach more than another interface would.

## Notes on evidence

- Policy/graph: `dart run tool/check_architecture.dart` → "912 owned files; 27
  exact exceptions", run 3× with identical output; `dart test test/architecture/`
  → 22 passed. `terminalPackages` at `tool/architecture/policy.json:16`;
  direction rule at `tool/architecture/policy.dart:111`.
- Headless path read end-to-end: `bin/tina.dart:487` onward (command mount at
  `:559`, dispatch at `:569`, one-turn run at `:594+`).
- Auto-answer evidence: `lib/pipeline/tina_interviewer.dart:14,26`;
  `packages/tina_app/lib/src/workflows/ask_user_tool.dart:83-90`; `lib/host/tui_conversation_host.dart:257-267`;
  `packages/tina_engine/lib/src/permissions/prompt.dart:290` (`decidedBy` default `'user'`).
- Engine/app `dart:io` counts: 44 files (`packages/tina_engine/lib`) and 27
  files (`packages/tina_app/lib`), by grep.
- PTY stack consumer search: `PtyRunner` grep across `lib/`, `bin/`,
  `packages/tina_app/`, `tool/`, `test/` → zero hits; engine barrel has no
  `terminal/` export; `docs/features/pty_backend.md:25` imports by `src/` path.
- Build-dep inheritance: `pubspec.lock:82` and
  `packages/tina_app/pubspec.lock:66` both resolve the `code_assets` graph.
- Prior art in-repo: `docs/proposals/remote_answerable_approvals.md` (daemon
  recipe, Part 3; ask records, Part 4), `docs/proposals/architecture/01-runtime-isolation.md:75`
  ("terminal ownership and child-process reaping remain process-owned"),
  `docs/features/terminal_panel_plan.md` (panel placement),
  `spikes/dart_wasm_worker/README.md` (workerd verdict).

## Corrections after external review

An external design review checked commit `bc6cbe5` against the source.
Its verdict: the central findings of this audit hold — the seams are
real (`HostInterface`, `AgentSink`/`AgentEventBus`,
`CommandRegistry.dispatch`, `InputRoutes`, `TurnExecutor`,
`SessionStore`/`SessionIndex`); unattended questions auto-answer;
automatic denials are attributed to the user; fixing the three gaps
does not require a daemon; wasm/browser is a separate port. Four claims
were corrected, each verified in the source before the edit:

1. **"A second front end does not need to invent a protocol" → softened.**
   The seams remove the *core rewrite*, not the protocol. `ask_user`
   answers `Question`/`Answer` via the attractor `Interviewer`
   (`packages/attractor/lib/src/interviewer.dart:31,57,90-91`) — not
   `PermissionAsker`; plan approval is persisted `requested` state in
   `PlanStore` (`plan_store.dart:169`) whose waiting is model guidance
   in the `update_plan` description (`plan_plugin.dart:161-170`). A
   remote front end writes one adapter per seam, plus transport
   serialization, routing, cancellation, reconnect. Applied in Finding
   1 ("Cost") and the ticket.

2. **"Move the build deps out of `dependencies`" → withdrawn.** While
   `hook/build.dart` stays in the engine, `code_assets`/`hooks`/
   `native_toolchain_c` must be regular dependencies: consumers execute
   the hook, and Dart ignores a dependency's dev dependencies in their
   resolution — the move could break downstream builds
   (`hook/build.dart:8-10`; dart.dev, "Dev dependencies"). Only
   extracting the PTY stack together with its hook and these deps
   removes the lockfile weight. Applied in Finding 5, roadmap row 4,
   and acceptance item 5 (now withdrawn with a replacement).

3. **"Nothing persists an open ask, so a late answer is dropped" —
   true, but the earlier companion-proposal claim that a store alone
   fixes it was not.** Parking stores the question; on today's
   executor a denial is a completed, failed tool result
   (`tool_executor.dart:620-649`) and the turn moves on, so a later
   approval has nothing to resume. Suspension/resume needs execution
   state, ask-id → `toolUseId` correlation, preserved sealed arguments
   (`tool_executor.dart:613-616`), revalidation, and duplicate-answer
   handling. Applied in acceptance item 2 and Finding 1's cost note.

4. **Ordering relaxed.** Restart durability was listed as a
   prerequisite for any transport work (roadmap row 2). It is not: a
   pending `Future` blocks nothing, so a live remote host on the
   existing async interfaces needs no store. New order: provenance +
   unattended defaults → narrow remote host on existing async
   interfaces (establishes the real contracts) → durable records →
   suspension/resume if the live host shows it is needed. PTY
   packaging stays a separate cleanup. Applied in the Summary and
   roadmap row 2.

Terminal-only framing: this audit never claimed permission *decisions*
must stay local, and the companion proposal's "what should stay
terminal-only" section was corrected there to split presentation (the
modal, wheel, overlays — TUI-only) from authorization (the decision —
remote-answerable).
