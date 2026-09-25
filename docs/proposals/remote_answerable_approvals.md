# Remote-answerable approvals — decoupling human decisions from the terminal

Status: proposed — nothing in Parts 3–5 exists on main. Part 1 and Part 2
document what is shipped today, read at `9aae45a` (v0.8.32, branch
`asb/approval-decoupling`). Every claim below was verified in code at that
commit; file and line are cited throughout.
Date: 2026-09-25.
Builds on: [`plugin_posture_door.md`](plugin_posture_door.md) (posture as a
core-minted value) and [`plugin_architecture.md`](plugin_architecture.md)
§11 (what plugins may do with approvals). It does not re-propose either.

## The question

Can every human decision in tina be answered from a plain text channel with
no terminal attached — a Signal message, an HTTP request, a queue? Typing
`/approve` in a chat window must work exactly as well as pressing `a` in the
TUI. Two extra facts drive the design:

1. **A chat answer arrives late.** Minutes, sometimes hours. A blocking
   `await` on a prompt cannot survive that.
2. **The ask must survive a restart.** If the process dies while an ask is
   pending, the answer must still land somewhere meaningful.

The honest summary up front:

- The **engine** is decoupled. The `PermissionAsker` typedef, `HostInterface`,
  and the plan gate all keep terminal specifics out of the core, and the core
  already runs unattended every day (sub-agents, headless runs).
- The **composition root** is not. Every interactive asker is built inside
  `TuiCoordinator` against a local screen and keyboard. There is no other
  interactive implementation to swap in.
- **No ask is durable.** Every pending ask lives in one `await` in one
  process. Restart = the ask is gone.
- Three unattended paths are **fail-open** (they answer *yes* for the human),
  and one audit hole attributes structural denials to "the user".

Parts 1–2 prove those statements. Part 3 assesses the daemon question.
Parts 4–5 propose the smallest set of changes that makes every decision
point answerable by text, without breaking the TUI.

---

## Part 1 — inventory of human-decision points

Legend: **Remote today?** asks whether a text-only frontend (chat bridge,
HTTP client) could deliver the answer with the code on main. **Stored?**
asks whether the *pending ask* survives anywhere but process memory.

| # | Who asks (file:line) | What is presented | Answered today | Transport assumed | Remote today? | Stored? |
|---|---|---|---|---|---|---|
| 1 | Main-conversation permission ask — `TuiConversationHost.askPermission`, `lib/host/tui_conversation_host.dart:244-286` | Modal approval card (`ApprovalCard`, `lib/tui/approval_card.dart:8`) with y/n/a/d/r choices, regex-review sub-modal (`lib/tui/regex_review.dart:6`) | Raw keys through the shared line editor | TTY, raw mode, terminal focused on this conversation (background → refuse, row 3) | **No** — the only interactive asker is built against `screen`/`editor` | No |
| 2 | Workflow-node permission ask — `WorkflowPermissionAsker`, `lib/pipeline/workflow_permission_asker.dart:22`, wired at `lib/tui_coordinator.dart:564-592` | Same card, rendered into the run's panel | Raw keys, queued behind other modals (`workflow_permission_asker.dart:51-64`) | TTY | **No** | No |
| 3 | Background-conversation ask — same host when the conversation is not foreground (`tui_conversation_host.dart:248-263`) | Dim refusal line in the panel | Nobody — structural auto-deny, `decidedBy: 'background'` (line 258) | None | n/a (already unattended) | No |
| 4 | Plan approval — `PlanTool` gate + `/plan` command + strip badge + overlay (`packages/tina_app/lib/src/plans/plan_plugin.dart:119-156`, `lib/composition/plan_ui.dart:13-35`) | Plan card; strip badge; overlay | Typed `/plan approve\|reject` (transport-neutral by shape) + arrow-key overlay | Mixed: typed command **and** raw-key overlay | **Partly** — the answer is a typed command, but command dispatch lives in the TUI input loop; headless has no answering path, so the gate auto-grants instead (`plan_plugin.dart:146-147`) | Plan + approval yes (`PlanStore`, manifest-persisted); the *ask* no |
| 5 | Trust gate — `_askTrustStdin`, `bin/tina.dart:989-1000`, resolved at `bin/tina.dart:971-985` | Plain stdin line: "Trust this project? … Load it? [y/N]" | Typed `y`/`N` on stdin, before the TUI starts | stdin is a terminal (`stdioType(stdin) == StdioType.terminal`, `tina.dart:976`) | **No** — but the decision is pre-settable: `--trust`/`--no-trust` (`tina.dart:982`, `lib/config.dart:525-531`) and `[trust] default` = always/never/ask (`packages/tina_app/lib/src/project/project_trust.dart:9`, precedence at `project_trust.dart:85-109`) | Decision yes (`ProjectTrustStore` under `~/.tina`, best-effort write at `project_trust.dart:63`); the pending ask no |
| 6 | First-run setup wizard — `bin/tina.dart:204-214` (stdin path), overlay when tty (`tina.dart:857`) | Line-oriented questions | Typed stdin lines (`readLineSync`, `tina.dart:214`) | stdin (tty or not — the non-tty path is explicit, `tina.dart:850-877`) | **Partly** — already line-oriented text; the transport is the local process's stdin | Written to config at the end |
| 7 | `ask_user` tool — `packages/tina_app/lib/src/workflows/ask_user_tool.dart:9`, TUI path via the coordinator's `askUser` callback (`agent_composition.dart:282-284`, overlay backed by `lib/tui/spawn_overlay.dart:593`) | Multiple-choice card | Arrow keys / selection | TTY | **No** — but this is the most remote-ready surface: the tool already speaks a structured Question/Answer protocol | No |
| 8 | Workflow human gate (`wait.human` node) — `HumanGateHandler(interviewer)`, interviewer chosen at `packages/tina_app/lib/src/workflows/pipeline_runner.dart:136-137` | A question card in the run panel | Selection via `TinaInterviewer` (`lib/pipeline/tina_interviewer.dart:35`); **headless auto-answers YES** via `HeadlessInterviewer` (`headless_interviewer.dart:8-21`) | TTY when interactive | **No** | No |
| 9 | Loop-budget pause — `onLoopBudgetExceeded`, `pipeline_runner.dart:174-179` | Warning + pause for a human decision | Interactive: via the interviewer; headless: aborts, no hook | TTY | **No** | No |
| 10 | Sub-agent permission asks — `SubAgentScheduler`, `packages/tina_engine/lib/src/agent/sub_agent_scheduler.dart:858,1092` | Nothing — auto-deny asker (`sub_agent_scheduler.dart:1352-1353`) | Nobody — `denyOnce`, unattended by design | None | n/a (already unattended) | n/a |
| 11 | Permission-mode switch — `/permissions <mode>` typed command (`lib/session_commands/command_families.dart:905-941`) + Shift+Tab wheel (raw key) | Text output; mode chips on later asks | Typed command or wheel | Text **and** raw key | **Partly** — the command is plain text, but the runtime switcher is TUI-wired; headless reports it unavailable (`command_families.dart:937-941`) | Mode is session state, not persisted per ask |
| 12 | Sandbox-retry / outside-sandbox approval — same modal as #1 (`packages/tina_engine/lib/src/permissions/prompt.dart:53-60`) | Additional claim rows on the card | Raw keys | TTY | **No** | No |
| 13 | Startup session picker — `lib/session_commands/startup_session_picker.dart:7,31` | Numbered list + typed choice | Typed line via an injected `readLine` (dependency-injected, test-proven) | stdin | **Partly** — pure text already; transport is the local stdin | No |

Two surfaces the brief asked about that are **not** decision points:
`/classifier-review` (`command_families.dart:761`) is one-shot read-only
advice that never blocks, and the permission-mode *chip* is a display.

### The fail-open finds

Reading for transport coupling surfaced three places where tina answers a
human question **for** the human, in the permissive direction:

- `HeadlessInterviewer.ask` returns `AnswerValue.yes` for every yes/no and
  confirmation gate, and the first option for multiple choice
  (`headless_interviewer.dart:8-21`). `tina --workflow name` builds its
  runner with no interviewer at all (`bin/tina.dart:511-518`), so every
  `wait.human` gate in a headless workflow run approves itself.
- `ask_user` with no wired asker auto-selects the first option of each
  question and says so in its output (`ask_user_tool.dart:82-89`). The
  orchestrator registry even constructs that state deliberately:
  `AskUserTool(null)` at `packages/tina_app/lib/src/composition/orchestrator_tools.dart:29`.
- The plan gate auto-grants under the same conditions
  (`plan_plugin.dart:146-147`). That one is deliberate and documented
  (`plan_plugin.dart:109-117`) — fail-open with the reasoning attached.

Permission asks themselves are fail-**closed** everywhere: headless host
(`packages/tina_engine/lib/src/host/headless_host.dart:69-88`), background
conversation (`tui_conversation_host.dart:255-263`), scheduler
(`sub_agent_scheduler.dart:1352-1353`), workflow asker fallback
(`workflow_permission_asker.dart:70-84`). The asymmetry — writes deny,
questions and gates answer yes — is not written down anywhere as a rule,
and it is exactly backwards for a chat-bridge world, where "nobody home"
must default to *not deciding*.

### An audit hole found on the way

`PermissionResponse.decidedBy` records who answered: `'user'`,
`'classifier'`, `'headless'`, `'background'`
(`prompt.dart:269-274`). But its default is `'user'`
(`prompt.dart:290`), and three structural deniers do not set it:
the scheduler's auto-deny (`sub_agent_scheduler.dart:1352-1353`), the
workflow asker's no-editor fallback (`workflow_permission_asker.dart:75-83`),
and the conversation deny stub (`packages/tina_app/lib/src/session/conversation.dart:162-163`).
Their denials are audited as if the user had denied them
(`auditApproval(..., decidedBy: ...)` at
`packages/tina_engine/lib/src/agent/tool_executor.dart:603-607`; the doc at
`prompt.dart:271-273` says the field exists precisely to prevent this).
Remote channels make this matter: forensics on an unattended run must be
able to tell "the human said no" from "no human was reachable".

---

## Part 2 — the seams, tested

### 2.1 Is `PermissionAsker` a real abstraction?

Yes. It is a typedef, not a class hierarchy:
`typedef PermissionAsker = Future<PermissionResponse> Function(PermissionPrompt)`
(`prompt.dart:306`). The prompt it receives is UI-neutral — choices are
text keys with labels (`prompt.dart:74-79`), and the card is *rendered from*
that data by a TUI-side renderer (`lib/tui/approval_card.dart:6-8`, "Plugins
can supply Renderer<ApprovalCard>"). The response is data too: decision,
scope, rule, `decidedBy`, an optional model-facing note (`prompt.dart:286-294`).

Implementations on main, all pluggable at construction:

| Asker | Where | Behaviour |
|---|---|---|
| TUI host asker | `tui_conversation_host.dart:244-286` | Interactive modal; refuses in background |
| `WorkflowPermissionAsker.ask` | `workflow_permission_asker.dart:51` | Interactive modal in the run panel; deny fallback without editor |
| `modeAwareAsker(...)` wrapper | `packages/tina_engine/lib/src/permissions/mode_aware_asker.dart` (wired at `agent_composition.dart:385-392`, `tui_coordinator.dart:579-591`) | Classifier decides in `auto` mode; falls through to the wrapped asker |
| `HeadlessHost.askPermission` | `headless_host.dart:69-88` | Auto-deny, `decidedBy: 'headless'`, explanatory note |
| Scheduler auto-deny | `sub_agent_scheduler.dart:1352-1353` | Auto-deny for every delegated agent |
| `InvocationHost.askPermission` | `packages/tina_engine/lib/src/host/invocation_host.dart:17-28` | Holds/cancels forwards; a wrapper, not a policy |
| `Conversation._denyAsker` | `conversation.dart:162-163` | Deny stub for driver-only conversations |

Injection points prove the seam is load-bearing: `buildAgent` accepts an
`asker` and otherwise borrows the host's (`asker ?? host.askPermission`,
`agent_composition.dart:384`), and `PipelineRunner` accepts a
`permissionAskerBuilder` per run sink (`pipeline_runner.dart:126-135`).
The engine's own tests run the full loop with fake askers
(`packages/tina_engine/test/helpers/fake_host_interface.dart`).

**What blocks a remote asker today is therefore not the seam** — a
`PermissionAsker` backed by a chat bridge could be handed to `buildAgent`
this afternoon. Three things block it in practice:

1. **No durable pending-ask representation exists.** The asker is an
   in-process `Future`. Chat answers arrive after minutes or hours and must
   survive restarts; a `Future` does neither. (Evidence that this is real:
   `WorkflowPermissionAsker` queues a modal while the *user* is distracted —
   `workflow_permission_asker.dart:51-64` — but the queue is memory.)
2. **Every interactive implementation is raw-key TUI.** There is no
   second interactive asker to point at. The construction sites
   (`tui_coordinator.dart:564-592`) hard-wire `screen`, `editor`,
   `attentionQueue`.
3. **Foreground/background leaks into approval semantics**
   (`tui_conversation_host.dart:248`): "can ask" is derived from which
   panel is focused, a purely TUI notion, inside the host every other
   frontend must share.

### 2.2 Is `canAnswerQuestions` too coarse?

It is one boolean with one question behind it: "is there a human who can
answer a modal?" (`packages/tina_engine/lib/src/host/host_interface.dart:49`,
overridden false by `headless_host.dart:52`), forwarded through borrowed
views (`invocation_host.dart:31`). Today exactly one consumer reads it:
the plan gate (`plan_plugin.dart:147`), where `false` means *fail-open
auto-grant* because "there is no `/plan` and no overlay to answer through"
(`plan_plugin.dart:111-114`).

A Signal bridge breaks the boolean's implicit equation of *answerable* with
*answerable now, at this terminal*. The bridge host is genuinely
answerable — slowly, asynchronously, from anywhere. Marking it `false`
produces the wrong behaviour (silent auto-grant of plans); marking it
`true` with a synchronous asker produces hangs.

What has to replace it — in order of least disruption:

- Keep the boolean, but re-define it as **"a human can eventually answer"**,
  and make every consumer that *waits* consult the asker's actual
  capabilities instead of the flag. The plan gate is the only current
  waiter; under the redefinition the bridge host returns `true` and its
  asker parks asks durably — the gate keeps waiting, which is correct.
- The posture-door program already points at the durable shape: core mints
  a read-only posture value instead of having consumers read policy/host
  fields (`plugin_posture_door.md`, steps 1–3). Answerability belongs in
  that posture as a small enum — `modal` (TUI), `async` (bridge), `none`
  (headless) — replacing both the flag's two states and the separate
  `decidedBy` conventions with one machine.

What a boolean can never carry even redefined: *how long* an answer may
take, and *what happens when it never comes*. Those belong in the ask
record (Part 4, recommendation 2), not in the host flag.

### 2.3 Who owns the agent loop?

Three loops exist, and they must not be conflated:

- **The turn loop** is core-owned and frontend-free. `Agent`, the tool
  executor, and the driver run to completion against a `HostInterface` and
  a `PermissionAsker`, with no terminal type in sight
  (`agent_composition.dart:394-418` builds it from injected parts). The
  engine test suite exercises it with fakes.
- **The workflow loop** is core-adjacent and already parameterised:
  `PipelineRunner` takes interviewer and permission-asker builders at
  construction and a cancel signal per run
  (`pipeline_runner.dart:52-64,131-137`). Headless
  (`bin/tina.dart:511-518`) and TUI (`tui_coordinator.dart:532-593`) build
  it differently but neither owns its internals.
- **The session loop** — what happens between turns: who is foregrounded,
  who answers, which commands run — is `TuiCoordinator`'s
  (`lib/tui_coordinator.dart`, the 133 KB composition root). This is where
  the interviewer and asker builders are wired (`tui_coordinator.dart:544-592`),
  and headless has its own thinner twin (`_runNonInteractive`,
  `bin/tina.dart:487`).

So the plain answer: **the coordinator does not own the agent loop, but it
owns every bridge into it that a human answers through.** The coupling is
concentrated in construction, which is the cheap kind to fix — new
implementations plug in at `agent_composition.dart:384` and
`pipeline_runner.dart:131` without touching the engine. The expensive kind —
approval semantics tangled with focus state (`tui_conversation_host.dart:248`)
— lives in the shared host class the coordinator also owns.

### 2.4 Why does tina require a TTY?

It mostly doesn't. The binary branches on terminal-ness in four places:
the TUI raw-mode setup (`bin/tina.dart:47`), setup-mode selection
(`tina.dart:322`), the stdin-vs-overlay wizard choice (`tina.dart:857`),
and the trust gate's `hasUi` (`tina.dart:976`). Non-tty stdin is an
explicitly supported configuration: the setup wizard runs as a plain
stdin question loop (`tina.dart:204-214`, "Non-tty (piped/CI) first run:
the stdin wizard", `tina.dart:71`), and `--prompt` / `--workflow` run
entirely without a terminal (`config.dart:200` — `nonInteractive` is
`prompt != null || workflow != null`).

The hard requirement is the TUI's, not the program's: notcurses needs a
real terminal and takes it into raw mode. What I could **not** verify from
code is the report that piping stdout breaks tina: nothing in the source
rejects a non-tty stdout, and the headless paths write to stdout/stderr
unconditionally (`tina.dart:311` mirrors to stderr precisely when
non-interactive). If a piping failure exists it is a bug in the TUI
backend, not an architectural constraint — worth a repro ticket, but this
proposal does not depend on it.

### 2.5 Can parts of the system already run unattended?

Yes, extensively — and this is the strongest evidence the core is already
decoupled:

- **Sub-agents never ask.** The scheduler fields every delegated agent's
  asks with an auto-deny asker (`sub_agent_scheduler.dart:858,1092,1352-1353`).
  A `delegate` fan-out runs to completion with no human on any path.
- **Driver-only conversations** exist with a deny stub asker and a null
  host (`conversation.dart:139-163`) — scripted execution with no agent
  behind them.
- **Headless runs** (`--prompt`, `--workflow`) execute whole sessions via
  `HeadlessHost`, whose every ask is a structural deny with an explanatory
  note for the model (`headless_host.dart:69-88`).
- **Workflow node agents** share the run policy and whatever asker the
  builder supplies (`pipeline_runner.dart:114-135`); the builder, not the
  node, decides interactivity.

The asker is already an add-on the frontend supplies, not something the
core needs. That is the precedent Part 4 builds on: remote channels need
new *askers and hosts*, not a new core.

### 2.6 Existing non-TTY entry points

Shipped today: `--prompt` (one turn, audit trail under `~/.tina/runs`),
`--workflow <name>` (DOT pipeline), `--list`, `--models`, the stdin setup
wizard, `--resume <id>` combined with `--prompt`/`--workflow` (only the
bare picker form is rejected with those flags,
`config.dart:744-749`), and `--trust`/`[trust] default` to pre-answer the
trust gate. The session
command registry is transport-neutral — typed lines, injected I/O — but it
is only *reachable* through the TUI input loop or the narrow headless
dispatch (`lib/session_commands/headless_commands.dart`).

What does not exist: any socket, HTTP, or queue surface; any way for a
second process to attach to a live session; any durable representation of
a pending ask. `docs/proposals/session-persistence/` landed the plugin
store (`SessionStore`, `packages/tina_engine/lib/src/persistence/session_store.dart:366`;
service-key resolution since SP1), which persists conversations, trackers,
and manifests — it has no concept of an open question.

---

## Part 3 — the daemon question

**Is a daemon required to answer approvals remotely? No.** The missing
pieces are a durable ask record, a text ingress for answers, and
answerability nuance — none of which require a long-running service. A
`--prompt` run that hits an ask could park it in the session store, post
"approve? `tina approve <id>`" to a webhook, and exit non-zero; the answer
lands on the next run. That is ugly but honest, and it would prove the
hard parts (durability, ingress) before any server exists.

**Is a daemon still the right goal? Yes — but as a composition of pieces
that are each useful on their own, not as a rewrite.** The reasons a
service earns its keep here: sessions outlive chat windows (`/spawn`,
`/branch`, workflows run for hours); notifications and attention requests
want a live process; and the plugin architecture already assumes a
long-lived host — plugins activate into a scope, provide services by
`ServiceKey`, and may not touch approvals except through user surfaces
(`plugin_architecture.md` §11, the decided boundary). A bridge that answers
`/approve` is a *user surface* by that definition, so the boundary already
anticipates this shape rather than fighting it.

What the daemon would be, concretely — and how little is new:

| Daemon ingredient | Already exists? |
|---|---|
| Session loop that runs without a terminal | Yes — headless (`bin/tina.dart:487`) + driver/turn core |
| Host the transport talks to | `HostInterface` + asker seam (Part 2.1); a `DaemonHost` implements both |
| State that survives restart | `SessionStore` (plugin-provided since SP1–SP5) — but it holds no asks |
| A place for pending asks | **New** — a small ask record + store (Part 4) |
| An answer ingress | **New, small** — three session commands (`/approve`, `/deny`, `/answer`) |
| Posture an async host can declare | Posture door steps 1–3 (`plugin_posture_door.md`), extended with answerability |
| Multi-frontend focus/attention | **New** — but only if TUI and remote share one session; not required for v1 |

Boundary if/when it lands: the daemon owns a session loop per live
conversation; frontends (TUI, bridge, HTTP client) attach as *hosts* that
implement `HostInterface` and supply askers; what crosses the boundary is
data — prompts as records, answers as `PermissionResponse` values, events
as `AgentEvent`s. No approval logic crosses, because approval logic already
lives behind the asker seam on the core side. The posture door's step-4
scope key (`posture_door.md:117-124`) is how a bridge *plugin* would read
posture without a core wiring change.

The plugin runtime's synchronous `PluginFactory.build` is noted as a gap
for cloud backends (`session-persistence/README.md`, cross-program note) —
the same gap applies to a transport-backed ask store and lands in the
plugin-runtime program, not here.

**Rejected daemon shapes**: embedding the transport inside the TUI process
(couples again, kills the TUI's offline value); a second agent
implementation for remote (two cores to keep safe — §11's boundary exists
precisely to prevent a second decision path); making the remote channel a
*plugin that answers asks* (violates the §11 rule that plugins never
decide — the bridge must deliver answers *to* the asker, not be the
decider).

---

## Part 4 — recommendations, in order

Each lands green on its own. 1–2 are prerequisites for calling anything
remote-answerable; 3–4 make it true; 5 is the safety gate; 6 is the payoff.

### 1. Fix deny provenance (correctness; hours)

Every structural denier sets `decidedBy`: the scheduler deny becomes
`'scheduler'`, the workflow no-editor fallback `'no-asker'`, the
conversation stub `'unwired'`; the background case keeps `'background'`.
Mechanical: three one-line constructor changes, matching the existing
`'headless'` precedent (`headless_host.dart:69-88`). Add an architecture
test asserting no non-interactive asker returns a response whose
`decidedBy` is `'user'`.
Unlocks: trustworthy audit for every later step. Fixes a live
misattribution that exists on main today.
Does not fix: anything remote.

### 2. Make the ask durable (core; the keystone)

Introduce a pending-ask record — id, conversation id, kind (permission /
plan / question / gate), the prompt data (the card is already plain data),
created-at, status — and an `AskStore` provided through the plugin scope
exactly like `PlanStore` (`plan_ui.dart:13-34` is the template). Askers
gain the *option* to park: `HeadlessHost` (and later `DaemonHost`) writes
the record, emits "asked via channel X, id Y", and returns a denial whose
note says an answer may arrive — or, for hosts that stay alive, a future
completed when the record settles. Restart semantics: on load, pending
asks are re-deliverable; answers arriving for expired asks get an explicit
"too late" rather than silence. Nothing blocks by default; the TUI path is
untouched.
Costs: a new store contract + one engine type. Risks: replay confusion —
mitigated by ids and status, and by making expiry deny-once (matching the
existing "proceed without this tool" notes, `headless_host.dart:88`).
Unlocks: asks survive restart; blocking-vs-parking becomes a host choice.

### 3. Text ingress for answers (small; immediately useful)

`/approve <id> [note]`, `/deny <id> [note]`, `/answer <id> <n>` in the
session command registry — which is already typed, transport-neutral, and
dependency-injected (`startup_session_picker.dart:7` proves the pattern;
`/permissions` at `command_families.dart:905-941` is the template). Route
them in headless dispatch too, and teach `setPermissionMode`'s absent
switcher to degrade with the same message rather than being TUI-only
(`command_families.dart:937-941`). Answers map onto `PermissionResponse`
with `decidedBy: 'user'` — it really was a user, at a distance.
Costs: commands + dispatch. Risks: an answer channel is a security
surface; auth belongs to the transport, and the ask ids must be
unguessable. Unlocks: any chat bridge that can send one text line can
answer anything, with zero new core code.

### 4. Answerability in posture (builds on the posture door)

Land posture-door steps 1–3, then add one dimension to the minted posture:
answerability `modal | async | none`, replacing the bare flag read in the
plan gate. Redefine `canAnswerQuestions` as "a human can eventually
answer" (it stays, one consumer, documented), or retire it behind the
posture once the door lands. The plan gate's rule becomes: `none` →
auto-grant (today's behaviour, unchanged); `modal` → overlay;
`async` → park via the ask store and keep waiting, with the strip badge
showing *awaiting answer*.
Costs: small, and it retires the duplication the posture door already
targets. Risks: none beyond the door's own. Unlocks: a bridge host that is
honest about being slow; plan gates that wait instead of silently granting.

### 5. Fail-closed for unattended questions (safety; small)

`HeadlessInterviewer` and the null-asker `ask_user` should default to
*declining to decide* — cancel/skip the gate, surface "no human
reachable" — with today's auto-yes / auto-first-option behaviour available
behind an explicit flag (e.g. `--answer-gates auto`) for users who want
unattended runs to bull through. Permission asks stay fail-closed deny
(they already are). The plan gate keeps its documented auto-grant
(`plan_plugin.dart:109-117`) — it grants *its own plan*, which is a
different, smaller thing than answering arbitrary questions.
Costs: one flag, two behaviour switches, doc updates. Risks: headless
workflows that currently complete may start skipping gates — which is the
point, and why the flag exists. Unlocks: running an unattended session
without it silently agreeing with itself.

### 6. Then the daemon (`tina serve`)

A headless host whose `HostInterface` is a transport (HTTP/stdio first;
Signal is a client, not a core concern), composed from 2–5: ask store for
durability, command ingress for answers, posture for honesty. The TUI
remains a separate frontend on the same seams. Only worth starting after
2–5 exist, because the daemon is then mostly glue.
Does not fix: multi-frontend focus (two hosts, one conversation, who is
foregrounded) — deliberately deferred; it is a product question, not a
seam problem.

### What should stay terminal-only

- **The mid-stream approval modal** (y/n/a/d/r with regex rewrite). A
  security-sensitive decision wants the lowest-latency surface there is,
  shown exactly what is about to run, with one-keyplant answers. A chat
  round-trip is strictly worse for the human *and* safer to keep local.
- **The mode wheel, plan overlay, and inline diff preview.** Arrow-key
  selection over rendered diffs is a TUI superpower; reproducing it in
  text is a downgrade for the user sitting at the keyboard.
- **The pre-TUI trust and setup prompts** can gain config pre-sets (they
  have them: `--trust`, `[trust] default`) but should stay interactive
  when actually asked — they run before any session exists, so a remote
  channel has nothing to attach to yet.

Remote channels take the *async* decisions: long-running workflows, plan
approvals, `ask_user` questions, unattended-run notifications. The terminal
keeps the *synchronous* ones. That division is the design; making
everything generic would make the common case worse.

---

## Migration

1. Recommendation 1 alone (one commit, one architecture test).
2. Recommendation 5 alone (flag + tests for both surfaces).
3. Recommendation 2's store behind the plan-store precedent; askers adopt
   parking one host at a time (`HeadlessHost` first — it already has the
   note-and-deny shape).
4. Recommendation 3's commands, dispatchable in both TUI and headless.
5. Posture door steps 1–3, then the answerability dimension (4).
6. `tina serve` (6) once 2–5 have shipped and the seams have users.

Steps 1, 2, 3 are independent of each other; 4 depends on 3; 5 depends on
the posture door; 6 depends on all.

## Alternatives considered

- **Status quo + a chat bridge that injects keystrokes into the TTY.**
  Rejected: it re-couples the transport to raw keys, survives nothing,
  and two writers on one terminal is a corruption bug wearing a feature's
  clothes.
- **Auto-approve everything in remote mode.** Rejected: it is today's
  fail-open behaviour with better marketing; the audit hole (Part 1) shows
  how unattended denials already get misread, and approvals are the one
  surface where "nobody answered" must not mean "yes".
- **Make `PermissionAsker` async-with-callbacks now (no store).** Rejected:
  a `Future` that outlives the process is not a thing; the store is the
  actual requirement, and the typedef can stay exactly as it is.
- **Skip the posture work and have the daemon host read policy fields.**
  Rejected: that is the exact duplication `plugin_posture_door.md` exists
  to remove; a second consumer (the daemon) is the trigger its step 4
  waits for, not a reason to bypass steps 1–3.

## Acceptance

- Every `decidedBy` in the audit trail is accounted for: an architecture
  test fails when an asker with no human path returns `decidedBy: 'user'`
  (recommendation 1).
- Kill -9 a run with a parked ask; restart; deliver the answer; the tool
  result and audit line show the decision with `decidedBy: 'user'` and the
  ask id (recommendation 2).
- `/approve <id>` works from a plain stdin-driven session — no TUI
  component in the stack trace (recommendation 3).
- With an async host, a plan stays `awaiting answer` across a restart and
  the strip shows it; with `none`, the gate auto-grants exactly as on main
  (recommendation 4, plus the posture door's own acceptance tests).
- A headless `--workflow` run with a `wait.human` node skips the gate and
  says so, unless `--answer-gates auto` is passed (recommendation 5).
- Grep-verifiable: no approval semantics read terminal state — no
  `stdioType`/`hasTerminal`/focus checks outside `bin/tina.dart`, the TUI
  package, and `TuiConversationHost` (the last only for its own modal).
