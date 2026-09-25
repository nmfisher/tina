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

# Remote-answerable approvals — decouple human decisions from the terminal

## Context

Architecture review of whether every human decision in tina can be answered
from a plain text channel (Signal bridge, HTTP, queue) with no terminal
attached — and whether that needs a daemon. Full inventory, seam analysis,
and the proposal:
`docs/proposals/remote_answerable_approvals.md` (verified in code at
`9aae45a`).

The engine keeps terminal specifics out (the `PermissionAsker` typedef,
`prompt.dart:306`; UI-neutral `PermissionPrompt` data), and large parts
already run unattended (scheduler auto-deny `sub_agent_scheduler.dart:1352`,
headless host `headless_host.dart:69-88`). The composition root does not:
every interactive asker is built inside `TuiCoordinator` against a local
screen and keyboard, and no pending ask survives process death. Two defects
found on the way:

- **Fail-open unattended questions.** `HeadlessInterviewer` auto-answers
  yes (`headless_interviewer.dart:8-21`) and ask_user auto-picks the first
  option (`ask_user_tool.dart:82-89`), so unattended runs answer human
  questions permissively while permission asks deny — an asymmetry nowhere
  stated as a rule.
- **Deny provenance.** `decidedBy` defaults to `'user'` (`prompt.dart:290`)
  and three structural deniers leave it unset
  (`sub_agent_scheduler.dart:1352-1353`,
  `workflow_permission_asker.dart:75-83`, `conversation.dart:162-163`), so
  unattended denials are audited as user denials.

## Proposal

Six ordered steps in the linked document; the headline pieces:

1. Fix deny provenance (three one-line changes + an architecture test).
2. A durable pending-ask record + `AskStore`, plugin-provided like
   `PlanStore`; askers gain the option to park instead of block.
3. Text ingress: `/approve`, `/deny`, `/answer` commands (the session
   command registry is already transport-neutral).
4. Answerability as a posture dimension (builds on the posture door).
5. Fail-closed defaults for unattended questions, auto-answer behind an
   explicit flag.
6. `tina serve` — a headless host whose `HostInterface` is a transport —
   only after 1–5, at which point it is mostly glue.

Terminal-only by design: the mid-stream approval modal, mode wheel, plan
overlay, inline diff preview.

## Acceptance

- The acceptance list in `docs/proposals/remote_answerable_approvals.md`
  is the contract: every structural denial carries a non-`'user'`
  `decidedBy` (architecture test); a parked ask survives kill -9 and its
  answer lands after restart; `/approve <id>` works from a stdin-driven
  session with no TUI in the stack; plan gates show *awaiting answer* on
  an async host and auto-grant exactly as today on `none`; headless
  `wait.human` gates skip-and-say-so unless `--answer-gates auto`.
- Documentation only in this ticket; the steps above are separate code
  changes, each landing green on its own.
