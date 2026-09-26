# Remote-answerable approvals — answering human decisions without a terminal

Status: **proposed**. Parts 1 and 2 describe code that ships today. Every
claim in them was checked in the source at `9aae45a` (v0.8.32, branch
`asb/approval-decoupling`); file and line are cited throughout.
Everything from Part 3 on — the daemon verdict, the six recommendations,
the migration order, the alternatives, the acceptance list — is a
proposal. None of it is implemented on main.
Date: 2026-09-25; revised 2026-09-26 after an external design review
(see "Corrections after external review" at the end).
Builds on: [`plugin_posture_door.md`](plugin_posture_door.md) (posture as
a value the core creates) and
[`plugin_architecture.md`](plugin_architecture.md) §11 (what plugins may
do with approvals). This document does not re-propose either of them.

## Summary

I reviewed all 13 places tina asks a human to decide, and asked whether
plain text — a chat window, an HTTP client, a queue — could answer it
with no terminal attached. Permission asks — the dangerous kind — all
go through one function type (`PermissionAsker`), and the core already
runs unattended. The other ask kinds have their own seams: `ask_user`
uses the attractor `Interviewer` (`Question`/`Answer` values,
`packages/attractor/lib/src/interviewer.dart:31,57`), and plan
approvals persist a `requested` flag in `PlanStore`
(`plan_store.dart:169`) — the model waits on guidance in the tool
description (`plan_plugin.dart:161-170`), not on a suspended
permission call. A remote front end therefore writes one adapter per
seam, and adds transport serialization, routing, cancellation and
reconnect on top. The wiring is still the problem: every asker a human
answers is built inside `TuiCoordinator`, and no open question survives
a restart. Two defects ship today: three unattended paths answer
questions *for* the human, and automatic denials are audited as user
denials. A daemon is not needed to fix this, but it is the right goal.
Six steps, in order: record who denied; fail closed when unattended;
park open questions in a store; add `/approve`-style commands; add
answerability to posture; `tina serve`. (This summary and the migration
order were revised on 2026-09-26 after an external design review — see
"Corrections after external review" at the end.)

## Terms used below

- An **ask** is one question put to a human: a permission prompt, a plan
  approval, an `ask_user` question, a workflow gate.
- To **park** an ask is to write it to a store instead of holding it in
  memory, so it survives a restart and can be answered later.
- **Fail-open** means the system answers *yes* when no human answers.
  **Fail-closed** means it answers *no*.
- A **seam** is a boundary where the engine calls code that another part
  supplies. The asker seam is the boundary the engine uses to put a
  question to whatever front end is attached.
- **Posture** is the read-only value the core publishes about how this
  session may act. `plugin_posture_door.md` proposes it; this document
  only builds on it.

## The question

Suppose tina is running a long workflow and you are away from the
keyboard. A tool wants to run a command outside the sandbox. Today the
question appears in a modal in the terminal and waits. If nobody is at
the keyboard, it waits forever.

This proposal asks: can every decision tina puts to a human be answered
from a plain text channel instead — a Signal message, an HTTP request, a
queue? Typing `/approve` in a chat window must work as well as pressing
`a` in the TUI. Two facts about text channels drive the design:

1. **A chat answer arrives late.** Minutes, sometimes hours. A blocking
   `await` on a prompt cannot wait that long inside one *turn* — the
   agent turn must be allowed to end while the question is open. (The
   *process* can hold a pending `Future` for hours without blocking the
   event loop — a point the external review made, which is why a live
   daemon can carry in-memory pending asks, and why durability is a
   separate requirement from remoteness.)
2. **The ask must survive a restart.** If the process dies while a
   question is open, the answer must still land somewhere useful.

The answers, up front:

- The **engine** is decoupled. The `PermissionAsker` typedef,
  `HostInterface`, and the plan gate all keep terminal specifics out of
  the core, and the core already runs unattended every day (sub-agents,
  headless runs).
- The **wiring** is not. Every interactive asker is built inside
  `TuiCoordinator` against a local screen and keyboard. There is no
  second interactive implementation to swap in.
- **No ask is durable.** Every open question lives in one `await` in one
  process. Restart, and the question is gone.
- Three unattended paths are **fail-open** — they answer *yes* for the
  human — and one audit hole records automatic denials as user denials.

Parts 1 and 2 prove those statements in code. Part 3 answers the daemon
question. Part 4 proposes the smallest set of changes that makes every
decision point answerable by text, without breaking the TUI.

---

## Part 1 — every place tina asks a human

Legend for the table:

- **Remote today?** — could a text-only front end (chat bridge, HTTP
  client) deliver the answer, using the code on main?
- **Stored?** — does the *open question* survive anywhere outside process
  memory? (This is not asking whether the decision is remembered.)

| # | Who asks (file:line) | What the human sees | How it is answered today | Transport assumed | Remote today? | Stored? |
|---|---|---|---|---|---|---|
| 1 | Main-conversation permission ask — `TuiConversationHost.askPermission`, `lib/host/tui_conversation_host.dart:244-286` | Modal approval card (`ApprovalCard`, `lib/tui/approval_card.dart:8`) with y/n/a/d/r keys and a regex-review sub-modal (`lib/tui/regex_review.dart:6`) | Raw keys through the shared line editor | TTY, raw mode, terminal focused on this conversation (background → refuse, row 3) | **No** — the only interactive asker is built against `screen`/`editor` | No |
| 2 | Workflow-node permission ask — `WorkflowPermissionAsker`, `lib/pipeline/workflow_permission_asker.dart:22`, wired at `lib/tui_coordinator.dart:564-592` | The same card, drawn in the run's panel | Raw keys, queued behind other modals (`workflow_permission_asker.dart:51-64`) | TTY | **No** | No |
| 3 | Background-conversation ask — the same host when the conversation is not in the foreground (`tui_conversation_host.dart:248-263`) | A dim refusal line in the panel | Nobody — automatic deny, `decidedBy: 'background'` (line 258) | None | n/a (already unattended) | No |
| 4 | Plan approval — `PlanTool` gate + `/plan` command + strip badge + overlay (`packages/tina_app/lib/src/plans/plan_plugin.dart:119-156`, `lib/composition/plan_ui.dart:13-35`) | Plan card; strip badge; overlay | Typed `/plan approve\|reject` plus the arrow-key overlay | Mixed: typed command **and** raw keys | **Partly** — the answer is a typed command, but command dispatch lives in the TUI input loop. Headless has no way to answer, so the gate auto-grants instead (`plan_plugin.dart:146-147`) | Plan and approval yes (`PlanStore`, persisted in the manifest); the *ask* no |
| 5 | Trust gate — `_askTrustStdin`, `bin/tina.dart:989-1000`, resolved at `bin/tina.dart:971-985` | One line on stdin: "Trust this project? … Load it? [y/N]" | Typed `y`/`N` on stdin, before the TUI starts | stdin must be a terminal (`stdioType(stdin) == StdioType.terminal`, `tina.dart:976`) | **No** — but the decision can be preset: `--trust`/`--no-trust` (`tina.dart:982`, `lib/config.dart:525-531`) and `[trust] default` = always/never/ask (`packages/tina_app/lib/src/project/project_trust.dart:9`, precedence at `project_trust.dart:85-109`) | Decision yes (`ProjectTrustStore` under `~/.tina`, best-effort write at `project_trust.dart:63`); the open question no |
| 6 | First-run setup wizard — `bin/tina.dart:204-214` (stdin path), overlay when tty (`tina.dart:857`) | Line-oriented questions | Typed stdin lines (`readLineSync`, `tina.dart:214`) | stdin, tty or not — the non-tty path is explicit (`tina.dart:850-877`) | **Partly** — already plain text, but the transport is this process's stdin | Written to config at the end |
| 7 | `ask_user` tool — `packages/tina_app/lib/src/workflows/ask_user_tool.dart:9`; TUI path via the coordinator's `askUser` callback (`agent_composition.dart:282-284`, overlay backed by `lib/tui/spawn_overlay.dart:593`) | Multiple-choice card | Arrow keys / selection | TTY | **No** — but this is the surface closest to being remote-ready: the tool already speaks a structured Question/Answer protocol | No |
| 8 | Workflow human gate (`wait.human` node) — `HumanGateHandler(interviewer)`, interviewer chosen at `packages/tina_app/lib/src/workflows/pipeline_runner.dart:136-137` | A question card in the run panel | Selection via `TinaInterviewer` (`lib/pipeline/tina_interviewer.dart:35`); headless **auto-answers YES** via `HeadlessInterviewer` (`headless_interviewer.dart:8-21`) | TTY when interactive | **No** | No |
| 9 | Loop-budget pause — `onLoopBudgetExceeded`, `pipeline_runner.dart:174-179` | Warning plus a pause for a human decision | Interactive: via the interviewer. Headless: aborts, with no hook | TTY | **No** | No |
| 10 | Sub-agent permission asks — `SubAgentScheduler`, `packages/tina_engine/lib/src/agent/sub_agent_scheduler.dart:858,1092` | Nothing — auto-deny asker (`sub_agent_scheduler.dart:1352-1353`) | Nobody — `denyOnce`, unattended by design | None | n/a (already unattended) | n/a |
| 11 | Permission-mode switch — `/permissions <mode>` typed command (`lib/session_commands/command_families.dart:905-941`) plus the Shift+Tab wheel (raw key) | Text output; mode chips on later asks | Typed command or wheel | Text **and** raw keys | **Partly** — the command is plain text, but the runtime switcher is wired to the TUI; headless reports it unavailable (`command_families.dart:937-941`) | Mode is session state, not stored per ask |
| 12 | Sandbox-retry / outside-sandbox approval — the same modal as #1 (`packages/tina_engine/lib/src/permissions/prompt.dart:53-60`) | Extra claim rows on the card | Raw keys | TTY | **No** | No |
| 13 | Startup session picker — `lib/session_commands/startup_session_picker.dart:7,31` | Numbered list plus a typed choice | A typed line, through an injected `readLine` (dependency-injected, covered by tests) | stdin | **Partly** — already plain text; the transport is the local stdin | No |

Two surfaces that look like decision points but are not:
`/classifier-review` (`command_families.dart:761`) is one-shot, read-only
advice that never blocks, and the permission-mode *chip* is a display.

### Questions the machine answers itself, with "yes"

Reading the code for transport coupling turned up three places where
tina answers a human question **for** the human, in the permissive
direction:

- `HeadlessInterviewer.ask` returns `AnswerValue.yes` for every yes/no
  and confirmation gate, and the first option for multiple choice
  (`headless_interviewer.dart:8-21`). `tina --workflow name` builds its
  runner with no interviewer at all (`bin/tina.dart:511-518`), so every
  `wait.human` gate in a headless workflow run approves itself.
- `ask_user` with no wired asker auto-selects the first option of each
  question and says so in its output (`ask_user_tool.dart:82-89`). The
  orchestrator registry constructs that state on purpose:
  `AskUserTool(null)` at
  `packages/tina_app/lib/src/composition/orchestrator_tools.dart:29`.
- The plan gate auto-grants under the same conditions
  (`plan_plugin.dart:146-147`). That one is deliberate and documented
  (`plan_plugin.dart:109-117`) — fail-open, with the reasoning written
  down next to it.

In practice: run `tina --workflow release` from cron, and its
`wait.human` gates approve themselves at 3 a.m. Nobody said yes.

Permission asks themselves are fail-**closed** everywhere: the headless
host (`packages/tina_engine/lib/src/host/headless_host.dart:69-88`), the
background conversation (`tui_conversation_host.dart:255-263`), the
scheduler (`sub_agent_scheduler.dart:1352-1353`), and the workflow
asker's fallback (`workflow_permission_asker.dart:70-84`). So the rule
today, stated nowhere as a rule, is: writes deny, questions and gates
answer yes. That is the wrong way round for a chat bridge. When answers
arrive over text, "nobody home" must default to *not deciding*.

### The audit hole found on the way

`PermissionResponse.decidedBy` records who answered: `'user'`,
`'classifier'`, `'headless'`, `'background'`
(`prompt.dart:269-274`). But its default value is `'user'`
(`prompt.dart:290`), and three code paths that deny without asking a
human do not set it: the scheduler's auto-deny
(`sub_agent_scheduler.dart:1352-1353`), the workflow asker's no-editor
fallback (`workflow_permission_asker.dart:75-83`), and the conversation
deny stub (`packages/tina_app/lib/src/session/conversation.dart:162-163`).
Their denials are audited as if the user had denied them
(`auditApproval(..., decidedBy: ...)` at
`packages/tina_engine/lib/src/agent/tool_executor.dart:603-607`). The doc
comment at `prompt.dart:271-273` says the field exists precisely to
prevent this.

In practice: you read the audit trail after an unattended run and it
says the user denied. There was no user. Remote channels make this
matter more, because forensics on an unattended run must be able to tell
"the human said no" from "no human was reachable".

---

## Part 2 — the seams, tested

### 2.1 Does `PermissionAsker` really keep the terminal out?

Yes. It is a typedef, not a class hierarchy:

```
typedef PermissionAsker =
    Future<PermissionResponse> Function(PermissionPrompt)
```

(`prompt.dart:306`.) The prompt it receives carries no UI details.
Choices are text keys with labels (`prompt.dart:74-79`). The card is
*rendered from* that data by a TUI-side renderer
(`lib/tui/approval_card.dart:6-8`: "Plugins can supply
Renderer<ApprovalCard>"). The response is data too: decision, scope,
rule, `decidedBy`, and an optional note for the model
(`prompt.dart:286-294`).

The implementations on main, all pluggable at construction:

| Asker | Where | Behaviour |
|---|---|---|
| TUI host asker | `tui_conversation_host.dart:244-286` | Interactive modal; refuses when in the background |
| `WorkflowPermissionAsker.ask` | `workflow_permission_asker.dart:51` | Interactive modal in the run panel; deny fallback when there is no editor |
| `modeAwareAsker(...)` wrapper | `packages/tina_engine/lib/src/permissions/mode_aware_asker.dart` (wired at `agent_composition.dart:385-392`, `tui_coordinator.dart:579-591`) | Classifier decides in `auto` mode; otherwise falls through to the wrapped asker |
| `HeadlessHost.askPermission` | `headless_host.dart:69-88` | Auto-deny, `decidedBy: 'headless'`, with an explanatory note |
| Scheduler auto-deny | `sub_agent_scheduler.dart:1352-1353` | Auto-deny for every delegated agent |
| `InvocationHost.askPermission` | `packages/tina_engine/lib/src/host/invocation_host.dart:17-28` | Holds or cancels forwards; a wrapper, not a policy |
| `Conversation._denyAsker` | `conversation.dart:162-163` | Deny stub for driver-only conversations |

The injection points show the seam is real and used: `buildAgent`
accepts an `asker` and otherwise borrows the host's
(`asker ?? host.askPermission`, `agent_composition.dart:384`), and
`PipelineRunner` accepts a `permissionAskerBuilder` per run sink
(`pipeline_runner.dart:126-135`). The engine's own tests run the full
loop with fake askers
(`packages/tina_engine/test/helpers/fake_host_interface.dart`).

So the seam is **not** what blocks a remote asker. A `PermissionAsker`
backed by a chat bridge could be handed to `buildAgent` today. Three
things block it in practice:

1. **There is no durable representation of an open question.** The
   asker is an in-process `Future`. Chat answers arrive after minutes or
   hours and must survive restarts. A `Future` does neither. (Evidence
   that the need is real: `WorkflowPermissionAsker` already queues a
   modal while the *user* is distracted —
   `workflow_permission_asker.dart:51-64` — but that queue is memory.)
2. **Every interactive implementation is raw-key TUI.** There is no
   second interactive asker to point at. The construction sites
   (`tui_coordinator.dart:564-592`) hard-wire `screen`, `editor`, and
   `attentionQueue`.
3. **Foreground/background leaks into approval semantics**
   (`tui_conversation_host.dart:248`): "may I ask?" is derived from which
   panel is focused. That is purely a TUI notion, and it sits inside the
   host class that every other front end must share.

### 2.2 Is `canAnswerQuestions` too coarse?

It is one boolean asking one question: "is there a human who can answer
a modal?" (`packages/tina_engine/lib/src/host/host_interface.dart:49`,
set to false by `headless_host.dart:52`, forwarded through borrowed
views at `invocation_host.dart:31`.) Exactly one consumer reads it today:
the plan gate (`plan_plugin.dart:147`). There, `false` means *fail-open
auto-grant*, because "there is no `/plan` and no overlay to answer
through" (`plan_plugin.dart:111-114`).

A Signal bridge breaks the assumption hidden in that boolean: that
*answerable* means *answerable now, at this terminal*. A bridge host is
genuinely answerable — slowly, asynchronously, from anywhere. Mark it
`false` and you get the wrong behaviour: plans silently auto-grant.
Mark it `true` with a synchronous asker and the session hangs.

What has to replace it, in order of least disruption:

- Keep the boolean, but re-define it as **"a human can eventually
  answer"**. Make every consumer that *waits* consult what the asker can
  actually do, instead of the flag. The plan gate is the only consumer
  that waits today. Under the new definition the bridge host returns
  `true`, its asker parks asks durably, and the gate keeps waiting —
  which is correct.
- The posture-door work already points at the durable shape: the core
  creates a read-only posture value instead of consumers reading policy
  and host fields (`plugin_posture_door.md`, steps 1–3). Answerability
  belongs in that posture as a small enum — `modal` (TUI), `async`
  (bridge), `none` (headless) — replacing both the flag's two states and
  the separate `decidedBy` conventions with one mechanism.

A boolean can never carry, even redefined: *how long* an answer may
take, and *what happens when it never comes*. Those belong in the ask
record (Part 4, recommendation 2), not in the host flag.

### 2.3 Who owns the agent loop?

Three loops exist, and they must not be confused:

- **The turn loop** is owned by the core and knows nothing about front
  ends. `Agent`, the tool executor, and the driver run to completion
  against a `HostInterface` and a `PermissionAsker`. No terminal type
  appears anywhere (`agent_composition.dart:394-418` builds it from
  injected parts). The engine test suite runs it with fakes.
- **The workflow loop** sits next to the core and is already
  parameterised. `PipelineRunner` takes interviewer and
  permission-asker builders at construction, and a cancel signal per run
  (`pipeline_runner.dart:52-64,131-137`). Headless
  (`bin/tina.dart:511-518`) and TUI (`tui_coordinator.dart:532-593`)
  build it differently, but neither owns its internals.
- **The session loop** — what happens between turns: who is
  foregrounded, who answers, which commands run — is `TuiCoordinator`'s
  (`lib/tui_coordinator.dart`, the 133 KB composition root: the one
  place where the objects are built and wired together). This is where
  the interviewer and asker builders are wired
  (`tui_coordinator.dart:544-592`). Headless has its own thinner twin
  (`_runNonInteractive`, `bin/tina.dart:487`).

So: **the coordinator does not own the agent loop, but it owns every
route into it that a human answers through.** The coupling is
concentrated in construction, which is the cheap kind to fix — a new
implementation plugs in at `agent_composition.dart:384` and
`pipeline_runner.dart:131` without touching the engine. The expensive
kind — approval semantics tangled up with focus state
(`tui_conversation_host.dart:248`) — lives in the shared host class,
which the coordinator also owns.

### 2.4 Why does tina require a TTY?

Mostly, it doesn't. The binary branches on terminal-ness in four
places: the TUI raw-mode setup (`bin/tina.dart:47`), setup-mode
selection (`tina.dart:322`), the stdin-vs-overlay wizard choice
(`tina.dart:857`), and the trust gate's `hasUi` (`tina.dart:976`).
Non-tty stdin is an explicitly supported configuration. The setup wizard
runs as a plain stdin question loop (`tina.dart:204-214`; the comment at
`tina.dart:71` says "Non-tty (piped/CI) first run: the stdin wizard"),
and `--prompt` / `--workflow` run entirely without a terminal
(`config.dart:200`: `nonInteractive` is `prompt != null || workflow != null`).

The hard requirement belongs to the TUI, not the program: notcurses
needs a real terminal and puts it into raw mode. One thing I could
**not** verify from code is the report that piping stdout breaks tina.
Nothing in the source rejects a non-tty stdout, and the headless paths
write to stdout and stderr unconditionally (`tina.dart:311` mirrors to
stderr exactly when non-interactive). If a piping failure exists, it is
a bug in the TUI backend, not an architectural constraint. It deserves
a repro ticket. This proposal does not depend on it.

### 2.5 Can parts of the system already run unattended?

Yes, extensively — and this is the strongest evidence that the core is
already decoupled:

- **Sub-agents never ask.** The scheduler fields every delegated
  agent's asks with an auto-deny asker
  (`sub_agent_scheduler.dart:858,1092,1352-1353`). A `delegate` fan-out
  runs to completion with no human on any path.
- **Driver-only conversations** exist with a deny stub asker and a null
  host (`conversation.dart:139-163`) — scripted execution with no agent
  behind it.
- **Headless runs** (`--prompt`, `--workflow`) execute whole sessions
  through `HeadlessHost`, whose every ask is an automatic deny with an
  explanatory note for the model (`headless_host.dart:69-88`).
- **Workflow node agents** share the run policy and whatever asker the
  builder supplies (`pipeline_runner.dart:114-135`). The builder, not
  the node, decides interactivity.

The asker is already an add-on the front end supplies, not something
the core needs. That is the precedent Part 4 builds on: remote channels
need new *askers and hosts*, not a new core.

### 2.6 Existing non-TTY entry points

Shipped today: `--prompt` (one turn, audit trail under `~/.tina/runs`),
`--workflow <name>` (DOT pipeline), `--list`, `--models`, the stdin
setup wizard, `--resume <id>` combined with `--prompt`/`--workflow`
(only the bare picker form is rejected with those flags,
`config.dart:744-749`), and `--trust`/`[trust] default` to pre-answer
the trust gate. The session command registry is transport-neutral —
typed lines, injected I/O — but it is only *reachable* through the TUI
input loop or the narrow headless dispatch
(`lib/session_commands/headless_commands.dart`).

What does not exist: any socket, HTTP, or queue surface; any way for a
second process to attach to a live session; any durable representation
of an open question. `docs/proposals/session-persistence/` landed the
plugin store (`SessionStore`,
`packages/tina_engine/lib/src/persistence/session_store.dart:366`;
service-key resolution since SP1). It persists conversations, trackers,
and manifests. It has no concept of an open question.

---

## Part 3 — the daemon question

**Is a daemon required to answer approvals remotely? No.** The missing
pieces are a durable ask record, a text route in for answers, and finer
answerability than one boolean. None of those needs a long-running
service. A `--prompt` run that hits an ask could park it in the session
store, post "approve? `tina approve <id>`" to a webhook, and exit
non-zero. The answer lands on the next run. That is ugly but honest,
and it would prove the hard parts — durability and ingress — before any
server exists.

**Is a daemon still the right goal? Yes — but assembled from pieces
that are each useful on their own, not written as a rewrite.** A service
earns its keep here for three reasons. Sessions outlive chat windows
(`/spawn`, `/branch`, workflows that run for hours). Notifications and
attention requests want a live process. And the plugin architecture
already assumes a long-lived host: plugins activate into a scope,
provide services by `ServiceKey`, and may not touch approvals except
through user surfaces (`plugin_architecture.md` §11, the decided
boundary). A bridge that answers `/approve` *is* a user surface by that
definition, so the boundary already expects this shape rather than
fighting it.

What the daemon would be, concretely — and how little is new:

| Daemon ingredient | Already exists? |
|---|---|
| A session loop that runs without a terminal | Yes — headless (`bin/tina.dart:487`) plus the driver/turn core |
| A host for the transport to talk to | `HostInterface` + the asker seam (Part 2.1); a `DaemonHost` implements both |
| State that survives a restart | `SessionStore` (plugin-provided since SP1–SP5) — but it holds no asks |
| A place for open asks | **New** — a small ask record + store (Part 4) |
| A route in for answers | **New, small** — three session commands (`/approve`, `/deny`, `/answer`) |
| A posture an async host can declare | Posture door steps 1–3 (`plugin_posture_door.md`), extended with answerability |
| Focus/attention shared across front ends | **New** — but only if TUI and remote share one session; not required for v1 |

The boundary, if and when it lands: the daemon owns one session loop per
live conversation. Front ends — TUI, bridge, HTTP client — attach as
*hosts* that implement `HostInterface` and supply askers. Only data
crosses the boundary: prompts as records, answers as
`PermissionResponse` values, events as `AgentEvent`s. No approval logic
crosses, because approval logic already lives behind the asker seam on
the core side. The posture door's step-4 scope key
(`plugin_posture_door.md:117-124`) is how a bridge *plugin* would read
posture without a core wiring change.

The plugin runtime's synchronous `PluginFactory.build` is noted as a gap
for cloud backends (`session-persistence/README.md`, cross-program
note). The same gap applies to a transport-backed ask store, and it
lands in the plugin-runtime program, not here.

**Rejected daemon shapes:**

- Embedding the transport inside the TUI process. It re-couples the
  transport to the terminal, and it destroys the TUI's ability to work
  offline.
- A second agent implementation for remote. Two cores to keep safe —
  §11's boundary exists precisely to prevent a second decision path.
- Making the remote channel a *plugin that answers asks*. That violates
  the §11 rule that plugins never decide. The bridge must deliver
  answers *to* the asker, not be the decider.

---

## Part 4 — recommendations, in order

Each one lands green on its own. Recommendations 1–2 are prerequisites
for calling anything remote-answerable. Recommendations 3–4 make it
true. Recommendation 5 is the safety gate. Recommendation 6 is the
payoff.

### 1. Fix who-denied records (correctness; hours)

Every code path that denies without asking a human sets `decidedBy`.
The scheduler deny becomes `'scheduler'`. The workflow no-editor
fallback becomes `'no-asker'`. The conversation stub becomes
`'unwired'`. The background case keeps `'background'`. The change is
mechanical: three one-line constructor edits, matching the existing
`'headless'` precedent (`headless_host.dart:69-88`). Add an
architecture test asserting that no non-interactive asker returns a
response whose `decidedBy` is `'user'`.

Unlocks: an audit trail you can trust, for every later step. Fixes a
live misattribution that exists on main today.
Does not fix: anything remote.

### 2. Make the ask durable (core; the keystone)

Introduce a pending-ask record: id, conversation id, kind (permission /
plan / question / gate), the prompt data (the card is already plain
data), created-at, status. Add an `AskStore` provided through the
plugin scope exactly like `PlanStore` (`plan_ui.dart:13-34` is the
template). Askers gain the *option* to park: `HeadlessHost` (and later
`DaemonHost`) writes the record, emits "asked via channel X, id Y", and
returns a denial whose note says an answer may still arrive. Hosts that
stay alive can instead return a future that completes when the record
settles. Restart semantics: on load, open asks can be delivered again;
an answer that arrives for an expired ask gets an explicit "too late"
rather than silence. Nothing blocks by default. The TUI path is
untouched.

Costs: the ask record and store contract for parking, plus — if late
answers must actually resume paused work — a suspension/resume design
in the turn loop (see the correction of record below; the earlier
"one new store contract plus one engine type" estimate was wrong).
Risks: replay confusion. Mitigated by ids and status, and by making
expiry deny once (matching the existing "proceed without this tool"
notes, `headless_host.dart:88`).
Unlocks: asks survive restart as *records*; block-or-park becomes a
choice each host makes.

**What parking does not do — correction of record (2026-09-26).** An
earlier version of this section claimed the store plus a record type
buys restart-surviving approvals. An external review caught the error,
and the code confirms it: parking stores the *question*, but nothing in
today's engine suspends the *work*. When an asker denies, the executor
returns a completed, failed tool result and the turn moves on
(`tool_executor.dart:620-649`) — the model is told the command was not
executed, and it proceeds. A later `/approve <id>` has no paused
operation to land on. For a late answer to resume the original call,
the engine needs explicit execution state (running / awaiting-decision
/ settled), correlation from ask id to `toolUseId`, preserved sealed
arguments (the snapshot the executor already takes before
authorization, `tool_executor.dart:613-616`), revalidation of the
decision against current policy and phase when the answer arrives, and
duplicate-answer handling (two `/approve` lines for one id; an answer
for an expired ask). That is a turn-loop design, priced as its own
piece of work. This recommendation keeps the ask record — routing,
display, and the audit trail need it — but no longer claims it makes
execution resumable.

### 3. A text route in for answers (small; immediately useful)

Add `/approve <id> [note]`, `/deny <id> [note]`, and
`/answer <id> <n>` to the session command registry. The registry is
already typed, transport-neutral, and dependency-injected
(`startup_session_picker.dart:7` proves the pattern; `/permissions` at
`command_families.dart:905-941` is the template). Route the commands in
headless dispatch too, and teach `setPermissionMode`'s missing switcher
to degrade with the same message instead of being TUI-only
(`command_families.dart:937-941`). Answers map onto
`PermissionResponse` with `decidedBy: 'user'` — it really was a user,
at a distance.

Costs: the commands plus dispatch.
Risks: an answer channel is a security surface. Authentication belongs
to the transport, and ask ids must be unguessable.
Unlocks: any chat bridge that can send one text line can answer
anything, with zero new core code.

### 4. Answerability in posture (builds on the posture door)

Land posture-door steps 1–3, then add one dimension to the posture: 
answerability `modal | async | none`, replacing the bare flag read in
the plan gate. Either re-define `canAnswerQuestions` as "a human can
eventually answer" (it stays, it has one consumer, it gets documented),
or retire it behind the posture once the door lands. The plan gate's
rule becomes: `none` → auto-grant (today's behaviour, unchanged);
`modal` → overlay; `async` → park via the ask store and keep waiting,
with the strip badge showing *awaiting answer*.

Costs: small, and it removes duplication the posture door already
targets.
Risks: none beyond the door's own.
Unlocks: a bridge host that can say honestly that it is slow; plan gates
that wait instead of silently granting.

### 5. Fail closed for unattended questions (safety; small)

`HeadlessInterviewer` and the null-asker `ask_user` should default to
*declining to decide*: cancel or skip the gate, and say "no human
reachable". Keep today's auto-yes / auto-first-option behaviour behind
an explicit flag (for example `--answer-gates auto`) for users who want
unattended runs to push through. Permission asks stay fail-closed deny
— they already are. The plan gate keeps its documented auto-grant
(`plan_plugin.dart:109-117`): it grants *its own plan*, which is a
different and smaller thing than answering arbitrary questions.

Costs: one flag, two behaviour switches, doc updates.
Risks: headless workflows that complete today may start skipping gates.
That is the point, and it is why the flag exists.
Unlocks: running an unattended session without it silently agreeing
with itself.

### 6. Then the daemon (`tina serve`)

A headless host whose `HostInterface` is a transport — HTTP or stdio
first; Signal is a client, not a core concern — composed from
recommendations 2–5: the ask store for durability, the command ingress
for answers, the posture for honesty. The TUI remains a separate front
end on the same seams. Start it after the recommendations above exist.

Honest pricing (per the external review): "mostly glue" was an
overstatement. The daemon is small *next to a core rewrite*, but it
still writes real adapters per ask seam (`PermissionAsker`,
`Interviewer`/`Question`/`Answer`, the plan store's `requested` flag),
plus transport serialization, routing, cancellation, and reconnect
behavior. What "no core rewrite" promises is exactly that: new host +
adapters, not a new engine.

Does not fix: focus shared across front ends (two hosts, one
conversation — who is foregrounded?). Deliberately deferred; that is a
product question, not a seam problem.

### What should stay terminal-only

The split is **presentation vs authorization**. What stays terminal-only
is the *presentation* of the fast, synchronous decisions — not the
underlying decision itself. A decision that must be reachable from a
chat window stays reachable; only its keyboard-first rendering is local.

- **The mid-stream approval modal as a widget** (y/n/a/d keys, regex
  rewrite, one-key answers). It is the fastest surface for a person at
  the keyboard and shows exactly what is about to run. The *decision*
  behind it must stay remote-answerable — "approve a blocked operation
  while away" is the point of this whole proposal — so the modal is one
  front end over the same ask record, not the only route to the
  decision.
- **The mode wheel, plan overlay, and inline diff preview.** Arrow-key
  selection over rendered diffs is what a TUI is good at. Reproducing
  it in text is a downgrade for the person sitting at the keyboard.
- **The pre-TUI trust and setup prompts** can gain config presets —
  they already have them: `--trust`, `[trust] default` — but should
  stay interactive when they actually ask. They run before any session
  exists, so a remote channel has nothing to attach to yet.

Remote channels take the *async* decisions: long-running workflows,
plan approvals, `ask_user` questions, unattended-run notifications —
and, through the parked-ask route, the permission decisions too when no
one is at the keyboard. The terminal keeps the *synchronous,
keyboard-first presentation* of its own decisions. That split is the
design. Making every widget generic would make the common case worse
without making any decision safer.

---

## Migration

Revised 2026-09-26 after the external design review (previous order:
store → commands → posture → fail-closed → daemon; the correction and
the reason are in "Corrections after external review"). The new order
puts correctness first, then proves the remote path with the
*interfaces that already exist*, and only then adds durability:

1. Recommendation 1 alone (one commit, one architecture test).
2. Recommendation 5 alone (the flag, plus tests for both surfaces).
3. **A narrow remote-host implementation on the existing async
   interfaces** — a `DaemonHost`-shaped `HostInterface` over stdio or
   HTTP whose askers `await` the incoming answer. A Dart `Future` may
   stay pending for hours without blocking the event loop, and one
   service can hold many pending questions, so a *live* remote front
   end needs no store at all. This step is what establishes the real
   contracts: adapters per ask seam (`PermissionAsker`,
   `Interviewer`/`Question`/`Answer`, the plan store's `requested`
   flag), transport serialization, routing, cancellation, reconnect.
   Fail-open gaps found here feed straight back into step 2's flags.
4. Recommendation 3's commands, dispatchable from both TUI and headless.
5. Recommendation 2's ask store, following the plan-store precedent;
   askers adopt parking one host at a time (`HeadlessHost` first — it
   already has the note-and-deny shape). Durable *records* land here.
6. Posture door steps 1–3, then the answerability dimension
   (recommendation 4).
7. Durable *suspension and recovery* — the turn-loop work from the
   correction of record — only once a live remote host has shown which
   parts of it are actually needed.
8. `tina serve` (recommendation 6), composed from the pieces above.

Steps 1, 2 and 3 are independent of each other. Step 4 depends on step
3. Step 5 is where restart durability enters — as a requirement for
*records*, kept separate from the live-host path. Step 7 depends on 3
and 5. Step 8 depends on all of them. PTY packaging stays a separate
cleanup (tin-7b7k), unrelated to this order.

## Alternatives considered

- **Status quo, plus a chat bridge that injects keystrokes into the
  TTY.** Rejected: it re-couples the transport to raw keys, it survives
  no restart, and two programs writing to one terminal corrupt the
  display and the input. That is a bug dressed up as a feature.
- **Auto-approve everything in remote mode.** Rejected: it is today's
  fail-open behaviour with a better name. The audit hole in Part 1
  shows how unattended denials already get misread, and approvals are
  the one surface where "nobody answered" must not mean "yes".
- **Make `PermissionAsker` async-with-callbacks now, with no store.**
  Rejected *for restart durability*: a `Future` cannot outlive the
  process. The review's ordering point stands, though — for a *live*
  remote host, futures over the existing async interfaces are exactly
  right, and that path needs no store (see migration step 3). The store
  earns its place when asks must survive restarts or outlive the host
  that asked.
- **Skip the posture work and have the daemon host read policy
  fields.** Rejected: that is the exact duplication
  `plugin_posture_door.md` exists to remove. A second consumer — the
  daemon — is the trigger its step 4 waits for, not a reason to bypass
  steps 1–3.

## Acceptance

- Every `decidedBy` in the audit trail is accounted for. An
  architecture test fails when an asker with no human path returns
  `decidedBy: 'user'` (recommendation 1).
- Kill -9 a run with a parked ask. Restart. Deliver the answer. The
  *record* resolves: the audit line shows the decision, with
  `decidedBy: 'user'` and the ask id, and the UI/transport that asked
  learns the outcome (recommendation 2). This is a record-level
  criterion. Resuming the paused *tool call* itself is deliberately
  **not** claimed here — see the correction of record in
  recommendation 2: on main today a denial completes the tool result,
  and building real suspension/resume is separate future work with its
  own acceptance tests.
- `/approve <id>` works from a plain stdin-driven session — no TUI
  component in the stack (recommendation 3).
- With an async host, a plan stays *awaiting answer* across a restart
  and the strip shows it. With `none`, the gate auto-grants exactly as
  it does on main (recommendation 4, plus the posture door's own
  acceptance tests).
- A headless `--workflow` run with a `wait.human` node skips the gate
  and says so, unless `--answer-gates auto` is passed
  (recommendation 5).
- Checkable by grep: no approval semantics read terminal state — no
  `stdioType`/`hasTerminal`/focus checks outside `bin/tina.dart`, the
  TUI package, and `TuiConversationHost` (the last only for its own
  modal).

---

## Corrections after external review

An external design review of commit `bc6cbe5` checked this document's
claims against the source. Its verdict: the central findings hold (the
asker seam is real; unattended paths auto-answer; automatic denials are
audited as user denials; a daemon is not required to fix them). Four
claims were wrong, and the proposed ordering was too rigid. Each
correction is applied above at the place that makes the claim; this
section records what changed and why. Corrections were verified in the
source before being applied.

1. **"Store the ask, return a denial" does not make execution
   resumable.** The earlier text (recommendation 2) said parking plus a
   record type bought restart-surviving approvals, priced at "one new
   store contract plus one engine type." Wrong: when an asker denies,
   `tool_executor.dart:620-649` returns a completed, failed tool
   result — the turn ends, the model proceeds, and a later approval has
   no suspended operation to resume. Real resumption needs execution
   state, ask-id → `toolUseId` correlation, preserved sealed arguments
   (`tool_executor.dart:613-616`), revalidation at answer time, and
   duplicate-answer handling — a turn-loop design, priced as its own
   work. Applied in recommendation 2 (correction of record) and the
   acceptance list.

2. **The engine is not one seam, and "every question goes through
   `PermissionAsker`" was false.** The summary said so; it does not.
   Permission asks do. `ask_user` answers
   `Question`/`Answer` values through the attractor `Interviewer`
   (`interviewer.dart:31,57,90-91`); workflow gates use the same
   `Interviewer`; plan approval persists a `requested` flag in
   `PlanStore` (`plan_store.dart:169`) and the model's waiting is
   guidance in the `update_plan` tool description
   (`plan_plugin.dart:161-170`), not a suspended permission call. A
   remote front end writes one adapter per seam, plus transport
   serialization, routing, cancellation, and reconnect. "No core
   rewrite" stands; "no protocol invention" and "mostly glue" did not
   survive the review. Applied in the summary and recommendation 6.

3. **"What should stay terminal-only" conflated presentation with
   authorization.** The earlier text kept the *decision* local along
   with the modal — which forbids the motivating case, approving a
   blocked operation while away. The split is now stated as
   presentation vs authorization: the modal, wheel, overlays, and diff
   preview stay TUI-only as presentation; the underlying decisions stay
   answerable remotely. Applied in "What should stay terminal-only."

4. **The ordering treated restart durability as a prerequisite for
   remoteness.** It is not: a pending `Future` blocks nothing, so a
   live daemon can carry in-memory pending asks, and one service can
   hold many. Durability is a separate requirement for a separate
   property (surviving restart). The migration now proves the remote
   path on the existing async interfaces first (new step 3), and moves
   the store to step 5 and real suspension/resume to step 7. Applied
   in "Two facts" (fact 1), "Alternatives", and "Migration".

Not corrected (checked, holds): the four central findings listed at the
top; the who-denied evidence; the fail-open evidence; the daemon
ingredient table's "already exists?" column; the rejected-shapes list,
with the futures nuance added to the third entry.
