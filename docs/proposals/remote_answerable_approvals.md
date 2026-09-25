# Remote-answerable approvals — answering human decisions without a terminal

Status: **proposed**. Nothing from Part 3 down exists on main. Parts 1 and 2
describe what is shipped today, read at `9aae45a` (v0.8.32, branch
`asb/approval-decoupling`). Every claim below was checked in code at that
commit; file and line are cited throughout.
Date: 2026-09-25.
Builds on: [`plugin_posture_door.md`](plugin_posture_door.md) (the core
computes a read-only posture value) and
[`plugin_architecture.md`](plugin_architecture.md) §11 (what plugins may do
with approvals). Neither is re-proposed here.

## Summary

- **What I reviewed:** all 13 places where tina asks a human to decide
  something, and whether each one could be answered from plain text — a
  chat message, an HTTP request, a queue — with no terminal attached.
- **What I found:** the engine is ready. The permission ask is a plain
  function type, the prompt is plain data, and nothing in the core knows
  about terminals. The wiring above the engine is not ready: every
  interactive asker is built inside the TUI coordinator against a local
  screen and keyboard, and no pending question survives a restart. On top
  of that, three unattended paths answer *yes* on the human's behalf while
  permission asks deny, and one audit bug records automatic denials as if
  the user had denied them.
- **What I recommend:** six steps, in order — fix the audit bug, store
  pending questions on disk, add `/approve`, `/deny` and `/answer`
  commands, make answerability an explicit host property, make unattended
  questions default to "no answer" instead of "yes", and only then build
  `tina serve`. A daemon is not needed to start. It is the right end goal.

## The question

Today a human answers tina at a keyboard: `y` at an approval card, a typed
`/plan approve`, a number at the session picker. The question this document
answers: can every one of those decisions be made from a plain text channel
with no terminal attached — a Signal message, an HTTP request, a queue?
Typing `/approve` in a chat window must work exactly as well as pressing
`a` in the TUI.

Two facts about chat drive the whole design:

1. **A chat answer arrives late.** Minutes, sometimes hours. Code that
   blocks on one `await asker(prompt)` cannot sit there that long.
2. **The ask must survive a restart.** If the process dies while a question
   is pending, the answer must still land somewhere meaningful afterwards.

The honest position, up front:

- The **engine** is decoupled. The `PermissionAsker` typedef,
  `HostInterface`, and the plan gate all keep terminal specifics out of the
  core, and the core already runs unattended every day (sub-agents,
  headless runs).
- The **composition root** — the code that assembles the running program,
  `lib/tui_coordinator.dart` — is not decoupled. Every interactive asker is
  built inside it against a local screen and keyboard. There is no other
  interactive implementation to swap in.
- **No ask is durable.** Every pending ask lives in one `await` in one
  process. Restart means the ask is gone.
- Three unattended paths are **fail-open** — they answer *yes* for the
  human — and one audit hole records automatic denials as user denials.

Parts 1–2 back those statements with code. Part 3 answers the daemon
question. Part 4 proposes the smallest set of changes that makes every
decision point answerable by text, without breaking the TUI.

---

## Part 1 — inventory of human-decision points

Two words about the table:

- A **seam** is a place where one implementation can be swapped for another
  without editing either side. Part 2 tests which seams are real.
- **Remote today?** asks: could a text-only frontend (a chat bridge, an
  HTTP client) deliver this answer with the code that is on main?
  **Stored?** asks: does the *pending question* survive anywhere outside
  process memory?

| # | Who asks (file:line) | What the human sees | How it is answered today | Transport assumed | Remote today? | Stored? |
|---|---|---|---|---|---|---|
| 1 | Main-conversation permission ask — `TuiConversationHost.askPermission`, `lib/host/tui_conversation_host.dart:244-286` | Modal approval card (`ApprovalCard`, `lib/tui/approval_card.dart:8`) with y/n/a/d/r choices; regex-review sub-modal (`lib/tui/regex_review.dart:6`) | Single keypresses, read through the shared line editor | TTY, raw mode, and the terminal focused on this conversation (a background conversation is refused — row 3) | **No** — the only interactive asker is built directly against `screen` and `editor` | No |
| 2 | Workflow-node permission ask — `WorkflowPermissionAsker`, `lib/pipeline/workflow_permission_asker.dart:22`, wired at `lib/tui_coordinator.dart:564-592` | The same card, drawn in the run's panel | Single keypresses, queued behind other modals (`workflow_permission_asker.dart:51-64`) | TTY | **No** | No |
| 3 | Background-conversation ask — the same host, when the conversation is not foreground (`tui_conversation_host.dart:248-263`) | A dim refusal line in the panel | Nobody — automatic deny, `decidedBy: 'background'` (line 258) | None | n/a (already unattended) | No |
| 4 | Plan approval — `PlanTool` gate + `/plan` command + strip badge + overlay (`packages/tina_app/lib/src/plans/plan_plugin.dart:119-156`, `lib/composition/plan_ui.dart:13-35`) | Plan card; strip badge; overlay | Typed `/plan approve\|reject` plus an arrow-key overlay | Both: a typed command **and** raw keys | **Partly** — the answer is already a typed command, but only the TUI input loop dispatches commands; headless has no way to answer, so the gate grants by itself (`plan_plugin.dart:146-147`) | The plan and its approval yes (`PlanStore`, persisted with the manifest); the pending ask no |
| 5 | Trust gate — `_askTrustStdin`, `bin/tina.dart:989-1000`, resolved at `bin/tina.dart:971-985` | One plain stdin line: "Trust this project? … Load it? [y/N]" | Typed `y`/`N` on stdin, before the TUI starts | stdin must be a terminal (`stdioType(stdin) == StdioType.terminal`, `tina.dart:976`) | **No** — but the decision can be pre-set: `--trust`/`--no-trust` (`tina.dart:982`, `lib/config.dart:525-531`) and `[trust] default` = always/never/ask (`packages/tina_app/lib/src/project/project_trust.dart:9`, precedence at `project_trust.dart:85-109`) | The decision yes (`ProjectTrustStore` under `~/.tina`, best-effort write at `project_trust.dart:63`); the pending ask no |
| 6 | First-run setup wizard — `bin/tina.dart:204-214` (stdin path), overlay when tty (`tina.dart:857`) | Line-oriented questions | Typed stdin lines (`readLineSync`, `tina.dart:214`) | stdin, tty or not — the non-tty path is explicit (`tina.dart:850-877`) | **Partly** — already plain text lines; the transport is the local process's stdin | Written to config at the end |
| 7 | `ask_user` tool — `packages/tina_app/lib/src/workflows/ask_user_tool.dart:9`; TUI path via the coordinator's `askUser` callback (`agent_composition.dart:282-284`, overlay backed by `lib/tui/spawn_overlay.dart:593`) | Multiple-choice card | Arrow keys / selection | TTY | **No** — but this is the surface closest to ready: the tool already exchanges a structured Question/Answer protocol | No |
| 8 | Workflow human gate (`wait.human` node) — `HumanGateHandler(interviewer)`, interviewer chosen at `packages/tina_app/lib/src/workflows/pipeline_runner.dart:136-137` | A question card in the run panel | Selection via `TinaInterviewer` (`lib/pipeline/tina_interviewer.dart:35`); **headless auto-answers YES** via `HeadlessInterviewer` (`headless_interviewer.dart:8-21`) | TTY when interactive | **No** | No |
| 9 | Loop-budget pause — `onLoopBudgetExceeded`, `pipeline_runner.dart:174-179` | A warning plus a pause for a human decision | Interactive: through the interviewer; headless: aborts, no hook | TTY | **No** | No |
| 10 | Sub-agent permission asks — `SubAgentScheduler`, `packages/tina_engine/lib/src/agent/sub_agent_scheduler.dart:858,1092` | Nothing — auto-deny asker (`sub_agent_scheduler.dart:1352-1353`) | Nobody — `denyOnce`, unattended by design | None | n/a (already unattended) | n/a |
| 11 | Permission-mode switch — `/permissions <mode>` typed command (`lib/session_commands/command_families.dart:905-941`) + Shift+Tab wheel (raw key) | Text output; mode chips on later asks | Typed command or wheel | Both: text **and** raw key | **Partly** — the command is plain text, but the runtime switcher is wired to the TUI; headless reports it unavailable (`command_families.dart:937-941`) | Mode is session state, not persisted per ask |
| 12 | Sandbox-retry / outside-sandbox approval — same modal as #1 (`packages/tina_engine/lib/src/permissions/prompt.dart:53-60`) | Extra claim rows on the card | Raw keys | TTY | **No** | No |
| 13 | Startup session picker — `lib/session_commands/startup_session_picker.dart:7,31` | Numbered list plus a typed choice | Typed line through an injected `readLine` (dependency-injected, covered by tests) | stdin | **Partly** — already plain text; the transport is the local stdin | No |

Two surfaces we were asked to check are **not** decision points:
`/classifier-review` (`command_families.dart:761`) is one-shot read-only
advice that never blocks, and the permission-mode *chip* is a display.

### Finding: three unattended paths answer yes for the human

Reading the code for terminal coupling turned up three places where tina
answers a human question **for** the human, in the permissive direction:

- `HeadlessInterviewer.ask` returns `AnswerValue.yes` for every yes/no and
  confirmation gate, and the first option for multiple choice
  (`headless_interviewer.dart:8-21`). `tina --workflow name` builds its
  runner with no interviewer at all (`bin/tina.dart:511-518`). So every
  `wait.human` gate in a headless workflow run approves itself. In
  practice: an overnight workflow can walk itself through gates nobody
  ever saw.
- `ask_user` with no wired asker picks the first option of each question
  and says so in its output (`ask_user_tool.dart:82-89`). The orchestrator
  registry builds that state deliberately: `AskUserTool(null)` at
  `packages/tina_app/lib/src/composition/orchestrator_tools.dart:29`.
  In practice: an unattended run states its own preferences and moves on.
- The plan gate auto-grants under the same conditions
  (`plan_plugin.dart:146-147`). That one is deliberate and documented
  (`plan_plugin.dart:109-117`) — fail-open with the reasoning written
  down next to it.

Permission asks are the opposite everywhere. When no human is reachable,
they deny: headless host
(`packages/tina_engine/lib/src/host/headless_host.dart:69-88`), background
conversation (`tui_conversation_host.dart:255-263`), scheduler
(`sub_agent_scheduler.dart:1352-1353`), workflow asker fallback
(`workflow_permission_asker.dart:70-84`).

So the de facto rule is: writes deny, questions and gates answer yes. It is
not written down anywhere as a rule. For a chat bridge it is exactly
backwards: when nobody answers, the system should default to *not
deciding*. Step 5 fixes this.

### Finding: automatic denials are audited as user denials

`PermissionResponse.decidedBy` records who answered: `'user'`,
`'classifier'`, `'headless'`, `'background'` (`prompt.dart:269-274`). The
field exists precisely so a non-human decision never masquerades as a
user's (`prompt.dart:271-273`).

But its default value is `'user'` (`prompt.dart:290`), and three automatic
deniers never set it: the scheduler's auto-deny
(`sub_agent_scheduler.dart:1352-1353`), the workflow asker's no-editor
fallback (`workflow_permission_asker.dart:75-83`), and the conversation
deny stub (`packages/tina_app/lib/src/session/conversation.dart:162-163`).
The audit line is written by `auditApproval(..., decidedBy: ...)` at
`packages/tina_engine/lib/src/agent/tool_executor.dart:603-607`. Result:
those denials land in the audit trail as if the user had denied them.

Who feels it: anyone reading the audit after an unattended run cannot tell
"the human said no" from "no human was reachable". Remote channels make
this worse, because more runs are unattended. Step 1 fixes it.

---

## Part 2 — the seams, tested

### 2.1 Is `PermissionAsker` a real abstraction?

Yes. It is a function type, not a class hierarchy:

```
typedef PermissionAsker = Future<PermissionResponse> Function(PermissionPrompt)
```

(`prompt.dart:306`.) The prompt it receives has no UI in it: the choices
are text keys with labels (`prompt.dart:74-79`), and the TUI card is
*rendered from* that data by a TUI-side renderer (`lib/tui/approval_card.dart:6-8`,
"Plugins can supply Renderer<ApprovalCard>"). The response is data too:
decision, scope, rule, `decidedBy`, and an optional model-facing note
(`prompt.dart:286-294`).

Implementations on main, all swappable at construction:

| Asker | Where | Behaviour |
|---|---|---|
| TUI host asker | `tui_conversation_host.dart:244-286` | Interactive modal; refuses when the conversation is in the background |
| `WorkflowPermissionAsker.ask` | `workflow_permission_asker.dart:51` | Interactive modal in the run panel; deny fallback when there is no editor |
| `modeAwareAsker(...)` wrapper | `packages/tina_engine/lib/src/permissions/mode_aware_asker.dart` (wired at `agent_composition.dart:385-392`, `tui_coordinator.dart:579-591`) | The classifier decides in `auto` mode; otherwise falls through to the wrapped asker |
| `HeadlessHost.askPermission` | `headless_host.dart:69-88` | Auto-deny, `decidedBy: 'headless'`, with an explanatory note |
| Scheduler auto-deny | `sub_agent_scheduler.dart:1352-1353` | Auto-deny for every delegated agent |
| `InvocationHost.askPermission` | `packages/tina_engine/lib/src/host/invocation_host.dart:17-28` | Holds or cancels and forwards; a wrapper, not a policy |
| `Conversation._denyAsker` | `conversation.dart:162-163` | Deny stub for driver-only conversations |

The injection points are real and used: `buildAgent` accepts an `asker`
and otherwise borrows the host's (`asker ?? host.askPermission`,
`agent_composition.dart:384`), and `PipelineRunner` accepts a
`permissionAskerBuilder` per run sink (`pipeline_runner.dart:126-135`).
The engine's own tests run the full loop with fake askers
(`packages/tina_engine/test/helpers/fake_host_interface.dart`).

**So the seam is not what blocks a remote asker.** A `PermissionAsker`
backed by a chat bridge could be handed to `buildAgent` this afternoon.
Three things block it in practice:

1. **No pending ask is stored anywhere.** The asker is an in-process
   `Future`. A chat answer arrives after minutes or hours and may arrive
   after a restart; a `Future` survives neither. (The need is already
   visible: `WorkflowPermissionAsker` queues a modal while the *user* is
   distracted — `workflow_permission_asker.dart:51-64` — but that queue
   lives in memory.)
2. **Every interactive implementation is raw-key TUI.** There is no second
   interactive asker to point at. The construction sites
   (`tui_coordinator.dart:564-592`) hard-wire `screen`, `editor` and
   `attentionQueue`.
3. **Foreground/background leaks into approval semantics**
   (`tui_conversation_host.dart:248`): "can I ask?" depends on which panel
   has focus. Focus is a TUI concept, but it sits inside the host class
   that every other frontend must share.

### 2.2 Is `canAnswerQuestions` too coarse?

It is one boolean with one meaning: "is there a human who can answer a
modal right now?" (`packages/tina_engine/lib/src/host/host_interface.dart:49`,
returned false by `headless_host.dart:52`, forwarded through borrowed
views at `invocation_host.dart:31`.) Exactly one consumer reads it today:
the plan gate (`plan_plugin.dart:147`), where `false` means auto-grant,
because "there is no `/plan` and no overlay to answer through"
(`plan_plugin.dart:111-114`).

A Signal bridge breaks the boolean's hidden assumption that *answerable*
means *answerable now, at this terminal*. The bridge really is answerable
— slowly, asynchronously, from anywhere. Mark it `false` and you get the
wrong behaviour (plans silently auto-grant). Mark it `true` with a
synchronous asker and you get a hang.

What should replace it, cheapest first:

- Keep the boolean, but re-define it as **"a human can eventually
  answer"**, and make every consumer that *waits* consult the asker's
  actual capabilities instead of the flag. The plan gate is the only
  consumer that waits today. Under the new meaning a bridge host returns
  `true`, its asker parks the question durably, and the gate keeps
  waiting — which is correct.
- The posture-door program already points at the durable shape: the core
  computes a read-only posture value instead of letting consumers read
  policy and host fields (`plugin_posture_door.md`, steps 1–3).
  Answerability belongs in that value as a small enum — `modal` (TUI),
  `async` (bridge), `none` (headless) — replacing both the flag's two
  states and the separate `decidedBy` conventions with one mechanism.

What a boolean can never carry, even redefined: *how long* an answer may
take, and *what happens when it never comes*. Those belong on the ask
record (step 2, below), not on the host flag.

### 2.3 Who owns the agent loop?

There are three loops, and they are different things:

- **The turn loop** is owned by the core and knows nothing about
  frontends. `Agent`, the tool executor and the driver run to completion
  against a `HostInterface` and a `PermissionAsker`; no terminal type
  appears (`agent_composition.dart:394-418` builds it from injected
  parts). The engine test suite exercises it with fakes.
- **The workflow loop** sits next to the core and is already
  parameterised: `PipelineRunner` takes interviewer and permission-asker
  builders at construction, and a cancel signal per run
  (`pipeline_runner.dart:52-64,131-137`). Headless (`bin/tina.dart:511-518`)
  and TUI (`tui_coordinator.dart:532-593`) build it differently, but
  neither owns its internals.
- **The session loop** — what happens between turns: who is foregrounded,
  who answers, which commands run — is `TuiCoordinator`'s
  (`lib/tui_coordinator.dart`, the 133 KB composition root). The
  interviewer and asker builders are wired here
  (`tui_coordinator.dart:544-592`). Headless has a thinner twin
  (`_runNonInteractive`, `bin/tina.dart:487`).

So the plain answer: **the coordinator does not own the agent loop, but it
owns every bridge into it that a human answers through.** The coupling is
concentrated in construction code, which is the cheap kind to fix — a new
implementation plugs in at `agent_composition.dart:384` and
`pipeline_runner.dart:131` without touching the engine. The expensive kind
— approval semantics tangled with focus state
(`tui_conversation_host.dart:248`) — lives in the shared host class, which
the coordinator also owns.

### 2.4 Why does tina require a TTY?

Mostly it doesn't. The binary checks terminal-ness in four places: the TUI
raw-mode setup (`bin/tina.dart:47`), setup-mode selection (`tina.dart:322`),
the stdin-vs-overlay wizard choice (`tina.dart:857`), and the trust gate's
`hasUi` (`tina.dart:976`). Non-tty stdin is an explicitly supported
configuration: the setup wizard runs as a plain stdin question loop
(`tina.dart:204-214`; "Non-tty (piped/CI) first run: the stdin wizard",
`tina.dart:71`), and `--prompt` / `--workflow` run entirely without a
terminal (`config.dart:200` — `nonInteractive` is
`prompt != null || workflow != null`).

The hard requirement is the TUI's, not the program's: notcurses needs a
real terminal and puts it into raw mode. What I could **not** verify from
code is a report that piping stdout breaks tina: nothing in the source
rejects a non-tty stdout, and the headless paths write to stdout/stderr
unconditionally (`tina.dart:311` mirrors to stderr precisely when
non-interactive). If that failure exists, it is a bug in the TUI backend,
not an architectural constraint. It is worth a repro ticket, but this
proposal does not depend on it.

### 2.5 Can parts of the system already run unattended?

Yes, extensively — and this is the strongest evidence that the core is
already decoupled:

- **Sub-agents never ask.** The scheduler answers every delegated agent's
  asks with an auto-deny asker
  (`sub_agent_scheduler.dart:858,1092,1352-1353`). A `delegate` fan-out
  runs to completion with no human on any path.
- **Driver-only conversations** exist with a deny stub asker and a null
  host (`conversation.dart:139-163`) — scripted execution with no agent
  behind them.
- **Headless runs** (`--prompt`, `--workflow`) execute whole sessions via
  `HeadlessHost`, whose every ask is an automatic deny with an explanatory
  note for the model (`headless_host.dart:69-88`).
- **Workflow node agents** share the run policy and whatever asker the
  builder supplies (`pipeline_runner.dart:114-135`). The builder, not the
  node, decides interactivity.

The asker is already an add-on the frontend supplies, not something the
core needs. That is the precedent step 2 builds on: remote channels need
new *askers and hosts*, not a new core.

### 2.6 Existing non-TTY entry points

Shipped today: `--prompt` (one turn, audit trail under `~/.tina/runs`),
`--workflow <name>` (DOT pipeline), `--list`, `--models`, the stdin setup
wizard, `--resume <id>` combined with `--prompt`/`--workflow` (only the
bare picker form is rejected with those flags, `config.dart:744-749`), and
`--trust`/`[trust] default` to pre-answer the trust gate.

The session command registry is transport-neutral — typed lines with
injected I/O — but it is only *reachable* through the TUI input loop or
the narrow headless dispatch (`lib/session_commands/headless_commands.dart`).

What does not exist: any socket, HTTP or queue surface; any way for a
second process to attach to a live session; any stored form of a pending
ask. `docs/proposals/session-persistence/` landed the plugin store
(`SessionStore`,
`packages/tina_engine/lib/src/persistence/session_store.dart:366`;
service-key resolution since SP1), which persists conversations, trackers
and manifests — it has no concept of an open question.

---

## Part 3 — the daemon question

**Is a daemon required to answer approvals remotely? No.** The missing
pieces are a stored ask record, a text path for answers to come in, and a
more precise notion of answerability. None of them needs a long-running
service. A `--prompt` run that hits an ask could park it in the session
store, post "approve? `tina approve <id>`" to a webhook, and exit
non-zero; the answer lands on the next run. That is ugly but honest, and
it would prove the hard parts (durability, answer ingress) before any
server exists.

**Is a daemon still the right goal? Yes — assembled from pieces that are
each useful on their own, not written as one rewrite.** The reasons a
service earns its keep here: sessions outlive chat windows (`/spawn`,
`/branch`, workflows that run for hours); notifications and attention
requests want a live process; and the plugin architecture already assumes
a long-lived host — plugins activate into a scope, provide services by
`ServiceKey`, and may not touch approvals except through user surfaces
(`plugin_architecture.md` §11, the decided boundary). A bridge that
carries `/approve` is a *user surface* by that definition, so the boundary
already expects this shape rather than fighting it.

What the daemon would be, concretely, and how little of it is new:

| Daemon ingredient | Already exists? |
|---|---|
| A session loop that runs without a terminal | Yes — headless (`bin/tina.dart:487`) plus the driver/turn core |
| A host for the transport to talk to | Yes — `HostInterface` plus the asker seam (Part 2.1); a `DaemonHost` implements both |
| State that survives a restart | `SessionStore` (plugin-provided since SP1–SP5) — but it holds no asks |
| A place for pending asks | **New** — a small ask record plus a store (step 2) |
| An answer ingress | **New, small** — three session commands (`/approve`, `/deny`, `/answer`) |
| A posture an async host can declare | Posture door steps 1–3 (`plugin_posture_door.md`), extended with answerability |
| Multi-frontend focus/attention | **New** — but only if TUI and remote share one session; not required for v1 |

The boundary, if and when it lands: the daemon owns one session loop per
live conversation; frontends (TUI, bridge, HTTP client) attach as *hosts*
that implement `HostInterface` and supply askers; what crosses the
boundary is data — prompts as records, answers as `PermissionResponse`
values, events as `AgentEvent`s. No approval logic crosses, because
approval logic already lives behind the asker seam on the core side. The
posture door's step-4 scope key (`posture_door.md:117-124`) is how a
bridge *plugin* would read posture without a core wiring change.

One gap is out of scope here: the plugin runtime's synchronous
`PluginFactory.build` is noted as a problem for cloud backends
(`session-persistence/README.md`, cross-program note). The same gap
applies to an ask store backed by a transport, and it lands in the
plugin-runtime program, not this one.

**Rejected daemon shapes:**

- Embedding the transport inside the TUI process. It re-couples what this
  proposal decouples, and it takes away the TUI's ability to work offline.
- A second agent implementation for remote use. Two cores to keep safe —
  §11's boundary exists precisely to prevent a second decision path.
- Making the remote channel a *plugin that answers asks*. That violates
  the §11 rule that plugins never decide: the bridge must deliver answers
  *to* the asker, not be the decider.

---

## Part 4 — recommendations, in order

Each step lands green on its own. Steps 1–2 are prerequisites for calling
anything remote-answerable; 3–4 make it true; 5 is the safety gate; 6 is
the payoff.

### 1. Record who denied (correctness; hours)

Every automatic denier sets `decidedBy`: the scheduler deny becomes
`'scheduler'`, the workflow no-editor fallback `'no-asker'`, the
conversation stub `'unwired'`; the background case keeps `'background'`.
The change is mechanical: three one-line constructor changes, matching the
existing `'headless'` precedent (`headless_host.dart:69-88`). Add an
architecture test that fails when a non-interactive asker returns a
response whose `decidedBy` is `'user'`.

- Unlocks: a trustworthy audit trail for every later step. Fixes a live
  misattribution that exists on main today.
- Does not fix: anything remote.

### 2. Store the pending ask (core; the keystone)

Introduce a pending-ask record — id, conversation id, kind (permission /
plan / question / gate), the prompt data (the card is already plain
data), created-at, status — and an `AskStore` provided through the plugin
scope exactly like `PlanStore` (`plan_ui.dart:13-34` is the template).
"Parking" an ask means: write that record, tell the channel "asked via X,
id Y", and stop holding the question in memory.

Askers gain the *option* to park. `HeadlessHost` (and later `DaemonHost`)
writes the record and returns a denial whose note says an answer may still
arrive — or, for hosts that stay alive, a future that completes when the
record settles. Restart semantics: on load, pending asks can be delivered
again; an answer that arrives for an expired ask gets an explicit "too
late" rather than silence. Nothing blocks by default. The TUI path is
untouched.

- Costs: one new store contract plus one engine type.
- Risks: replay confusion — mitigated by ids and status, and by making
  expiry deny once (matching the existing "proceed without this tool"
  notes, `headless_host.dart:88`).
- Unlocks: asks survive restart; blocking-versus-parking becomes a host
  choice.

### 3. Commands that answer (small; immediately useful)

`/approve <id> [note]`, `/deny <id> [note]`, `/answer <id> <n>` in the
session command registry — which is already typed, transport-neutral and
dependency-injected (`startup_session_picker.dart:7` proves the pattern;
`/permissions` at `command_families.dart:905-941` is the template). Route
them in headless dispatch too, and teach `setPermissionMode`'s absent
switcher to degrade with the same message instead of being TUI-only
(`command_families.dart:937-941`). Answers map onto `PermissionResponse`
with `decidedBy: 'user'` — it really was a user, at a distance.

- Costs: the commands plus dispatch.
- Risks: an answer channel is a security surface; auth belongs to the
  transport, and ask ids must be unguessable.
- Unlocks: any chat bridge that can send one text line can answer
  anything, with zero new core code.

### 4. Answerability in posture (builds on the posture door)

Land posture-door steps 1–3, then add one dimension to the minted posture:
answerability `modal | async | none`, replacing the bare flag read in the
plan gate. Redefine `canAnswerQuestions` as "a human can eventually
answer" (it stays, one consumer, documented), or retire it behind the
posture once the door lands. The plan gate's rule becomes: `none` →
auto-grant (today's behaviour, unchanged); `modal` → overlay; `async` →
park via the ask store and keep waiting, with the strip badge showing
*awaiting answer*.

- Costs: small, and it removes duplication the posture door already
  targets.
- Risks: none beyond the door's own.
- Unlocks: a bridge host that is honest about being slow; plan gates that
  wait instead of silently granting.

### 5. Fail closed for unattended questions (safety; small)

`HeadlessInterviewer` and the null-asker `ask_user` should default to
*declining to decide*: cancel or skip the gate and say "no human
reachable". Keep today's auto-yes / auto-first-option behaviour behind an
explicit flag (e.g. `--answer-gates auto`) for users who want unattended
runs to push through. Permission asks stay fail-closed deny (they already
are). The plan gate keeps its documented auto-grant
(`plan_plugin.dart:109-117`) — it grants *its own plan*, which is a
smaller thing than answering arbitrary questions.

- Costs: one flag, two behaviour switches, doc updates.
- Risks: headless workflows that currently complete may start skipping
  gates. That is the point, and it is why the flag exists.
- Unlocks: running an unattended session without it silently agreeing
  with itself.

### 6. Then the daemon (`tina serve`)

A headless host whose `HostInterface` is a transport (HTTP or stdio
first; Signal is a client, not a core concern), composed from steps 2–5:
ask store for durability, command ingress for answers, posture for
honesty. The TUI stays a separate frontend on the same seams. Only worth
starting after 2–5 exist, because the daemon is then mostly glue.

- Does not fix: multi-frontend focus (two hosts, one conversation, who is
  foregrounded) — deliberately deferred; it is a product question, not a
  seam problem.

### What should stay terminal-only

- **The mid-stream approval modal** (y/n/a/d/r with regex rewrite). A
  security-sensitive decision wants the lowest-latency surface there is,
  showing exactly what is about to run, answerable with one key. A chat
  round-trip is strictly worse for the human *and* safer kept local.
- **The mode wheel, plan overlay, and inline diff preview.** Arrow-key
  selection over rendered diffs is a TUI strength; reproducing it in text
  is a downgrade for the user sitting at the keyboard.
- **The pre-TUI trust and setup prompts** can gain config pre-sets (they
  have them: `--trust`, `[trust] default`) but should stay interactive
  when actually asked — they run before any session exists, so a remote
  channel has nothing to attach to yet.

Remote channels take the *async* decisions: long-running workflows, plan
approvals, `ask_user` questions, unattended-run notifications. The
terminal keeps the *synchronous* ones. That division is the design;
making everything generic would make the common case worse.

---

## Migration

1. Step 1 alone (one commit, one architecture test).
2. Step 5 alone (the flag, plus tests for both surfaces).
3. Step 2's store behind the plan-store precedent; askers adopt parking
   one host at a time (`HeadlessHost` first — it already has the
   note-and-deny shape).
4. Step 3's commands, dispatchable in both TUI and headless.
5. Posture door steps 1–3, then the answerability dimension (step 4).
6. `tina serve` (step 6) once 2–5 have shipped and the seams have users.

Steps 1, 2 and 3 are independent of each other; 4 depends on 3; 5 depends
on the posture door; 6 depends on all.

## Alternatives considered

- **Status quo plus a chat bridge that injects keystrokes into the TTY.**
  Rejected: it re-couples the transport to raw keys, survives no restart,
  and two writers on one terminal corrupt each other — a bug dressed up
  as a feature.
- **Auto-approve everything in remote mode.** Rejected: it is today's
  fail-open behaviour with better marketing. The audit hole in Part 1
  shows how unattended denials already get misread, and approvals are the
  one surface where "nobody answered" must not mean "yes".
- **Make `PermissionAsker` async-with-callbacks now, with no store.**
  Rejected: a `Future` cannot outlive the process. The store is the actual
  requirement, and the typedef can stay exactly as it is.
- **Skip the posture work and have the daemon host read policy fields.**
  Rejected: that is the exact duplication `plugin_posture_door.md` exists
  to remove; a second consumer (the daemon) is the trigger its step 4
  waits for, not a reason to bypass steps 1–3.

## Acceptance

- Every `decidedBy` in the audit trail is accounted for: an architecture
  test fails when an asker with no human path returns `decidedBy: 'user'`
  (step 1).
- Kill -9 a run with a parked ask; restart; deliver the answer; the tool
  result and audit line show the decision with `decidedBy: 'user'` and the
  ask id (step 2).
- `/approve <id>` works from a plain stdin-driven session — no TUI
  component anywhere in the stack (step 3).
- With an async host, a plan stays `awaiting answer` across a restart and
  the strip shows it; with `none`, the gate auto-grants exactly as on main
  (step 4, plus the posture door's own acceptance tests).
- A headless `--workflow` run with a `wait.human` node skips the gate and
  says so, unless `--answer-gates auto` is passed (step 5).
- Grep-verifiable: no approval semantics read terminal state — no
  `stdioType`/`hasTerminal`/focus checks outside `bin/tina.dart`, the TUI
  package, and `TuiConversationHost` (the last only for its own modal).
