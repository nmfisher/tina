---
id: tin-3i3l
status: open
deps: []
links: [tin-n8vq]
created: 2026-09-25
type: proposal
priority: 2
assignee: Nick Fisher
tags: [permissions, approvals, headless, plugins, audit]
---

# Remote-answerable approvals — answering human decisions without a terminal

## Context

Architecture review answering two questions: can every human decision in
tina be answered from a plain text channel (Signal bridge, HTTP, queue)
with no terminal attached, and does that need a daemon? Full inventory,
seam analysis, and the proposal:
`docs/proposals/remote_answerable_approvals.md` (verified in code at
`9aae45a`).

The engine keeps terminal specifics out (the `PermissionAsker` typedef,
`prompt.dart:306`; UI-neutral `PermissionPrompt` data — the seam for
*permission* asks; `ask_user`/workflow gates use the attractor
`Interviewer` with `Question`/`Answer`, `interviewer.dart:90`, and plan
approval is persisted `PlanStore.requested` state), and large parts
already run unattended (scheduler auto-deny `sub_agent_scheduler.dart:1352`,
headless host `headless_host.dart:69-88`). The wiring does not: every
interactive asker is built inside `TuiCoordinator` against a local
screen and keyboard, and no open ask survives process death. Two defects
found on the way:

- **Fail-open unattended questions.** `HeadlessInterviewer` auto-answers
  yes (`headless_interviewer.dart:8-21`) and ask_user auto-picks the first
  option (`ask_user_tool.dart:82-89`), so unattended runs answer human
  questions permissively while permission asks deny — an asymmetry nowhere
  stated as a rule.
- **Who-denied records.** `decidedBy` defaults to `'user'`
  (`prompt.dart:290`) and three code paths that deny without asking a
  human leave it unset (`sub_agent_scheduler.dart:1352-1353`,
  `workflow_permission_asker.dart:75-83`, `conversation.dart:162-163`),
  so unattended denials are audited as user denials.

## Proposal

Six ordered steps in the linked document. The headline pieces:

1. Fix who-denied records (three one-line changes + an architecture
   test).
2. A durable pending-ask record + `AskStore`, plugin-provided like
   `PlanStore`; askers gain the option to park instead of block. The
   record survives restart (routing, display, audit trail). Resuming the
   paused tool call itself is separate, larger work — on today's executor
   a denial completes the tool result (`tool_executor.dart:620-649`) —
   see the document's correction of record.
3. A text route in for answers: `/approve`, `/deny`, `/answer` commands
   (the session command registry is already transport-neutral).
4. Answerability as a posture dimension (builds on the posture door).
5. Fail-closed defaults for unattended questions; auto-answer only
   behind an explicit flag.
6. `tina serve` — a headless host whose `HostInterface` is a transport —
   after the steps above. Small next to a core rewrite, but not glue:
   it writes one adapter per ask seam (`PermissionAsker`,
   `Interviewer`/`Question`/`Answer`, the plan store's `requested`
   flag) plus transport serialization, routing, cancellation, and
   reconnect (2026-09-26, external review).

Order revised 2026-09-26 (external review): 1 then 5 as below; then a
narrow remote host on the existing async interfaces — a pending Future
blocks nothing, so a live host needs no store — to establish the real
contracts; then 2's durable records; then 7 the turn-loop
suspension/resume work only if the live host shows it is needed.

Terminal-only by design: the mid-stream approval modal, mode wheel, plan
overlay, inline diff preview.

## Acceptance

- The acceptance list in `docs/proposals/remote_answerable_approvals.md`
  is the contract: every denial without a human carries a non-`'user'`
  `decidedBy` (architecture test); a parked ask survives kill -9 and its
  answer lands after restart; `/approve <id>` works from a stdin-driven
  session with no TUI in the stack; plan gates show *awaiting answer* on
  an async host and auto-grant exactly as today on `none`; headless
  `wait.human` gates skip-and-say-so unless `--answer-gates auto`.
- Documentation only in this ticket; the steps above are separate code
  changes, each landing green on its own.
