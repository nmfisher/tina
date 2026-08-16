---
id: tin-8n7c
status: closed
deps: []
links: [tin-6a2f]
created: 2026-08-15T15:12:00Z
type: bug
priority: 2
assignee: Nick Fisher
tags: [tui, approvals, input-routing, keys]
---
# Approval input: some approval prompts stop accepting 'a'/'y' — repeated keys vanish for minutes, then a different key resolves

## Context

During a sweep run (T10, 120x40, real deepseek provider), a bash permission
prompt stayed open for ~7 minutes while the approve-loop pressed 'a' every
~3-9 s (~60 presses). The prompt displayed no answer character (empty "› ").
The FIRST keystroke that visibly landed was 'x' (~1 s after the last 'a'
press), which the approval consumed as a deny ("bash denied"), after which the
agent moved on. The same session's earlier approvals (search, grep) resolved
on the first 'a'. A later session's approvals all resolved on 'a' fine.

So: keys pressed while THIS approval was open neither resolved it nor leaked
into the editor (the input line stayed empty) — they vanished entirely.

## Repro

1. tina TUI in a detached tmux session (tin-r2vd injection).
2. Ask a task whose agent issues several tool calls in sequence (search →
   grep → bash), approving each with 'a'.
3. When the bash approval appears, press 'a' repeatedly for a minute.
4. Observed: the approval never resolves; the answer char never appears; the
   editor input line stays empty. A later 'x' (or 'y') lands and resolves.

Not reproduced on every run (T1/T2/T3/T6/T5 ceremonies resolved 'a' normally),
which suggests a state-dependent input-routing failure: a stale consumer of
the shared editor readKey turn (see line_editor.dart readKey serialization and
the spend-pause dialog) that never releases, or a key consumed by the paste
burst path after prompt typing.

## Progress

One root cause found and fixed (commit 21af54e): the editor's `readKey`
drained its paste-overflow `_pending` unconditionally, so an approval issued
after a pasted submission consumed a stale paste char as its answer —
auto-denying ("bash denied" with no answer char). Fixed: only drain while
the burst window is open; drop stale overflow. Regression test added
(`stale paste overflow never answers a later readKey`), tina_console suite
670 green, root suite green (after tin-7b3p fix).

The OTHER observed failure mode remains: with the fix in place, an approval
prompt can still refuse keys pressed at a steady cadence (every ~3-6 s) for
minutes — no answer char displayed, editor stays empty — while a single
keypress after a pause resolves it. Repro (2026-08-15, fixed build): the
environment-agent ceremony's `glob: *` and `bash: cd ... && cat README.md
&& echo "=====ANALYSIS=====" && cat analysis_options.yaml` approvals ignored
~50 'y' presses at 3 s cadence, then resolved on a press after a pause.
Suggests an input-pump-level lost wakeup under steady key arrival (see
packages/dart_notcurses/native/src/input_pump.c notify/armed logic), not the
editor's pending queue.

## Acceptance

- An open approval always consumes the next keypress: 'y'/'a'/'d' resolve it
  and display the answer char; no keypress ever vanishes — including steady
  3 s cadence presses.
- Regression test: fake key source feeding keys to askPermission while a
  stale readKey turn is held must still deliver to the approval.

## Session findings (2026-08-16)

Repro attempts with the stub: approvals resolve on the FIRST keypress
('y' displays the answer char and the tool proceeds). Keys pressed at a
steady 0.5-3 s cadence DURING a running turn accumulate in the editor's
queue-mode buffer (by design — queue mode submits on Enter) and never
reach a pending approval, because no approval is pending at that point.
The ticket's exact "keys vanish while an approval pends" mode (answer char
never appears, editor stays empty) did not reproduce in ~10 runs.

The crash ticket tin-3x9v (linked) also failed to reproduce. Both may
share a trigger not present in the stub runs (real-provider pacing or a
specific turn state). tool/vanish_hunt.sh drives steady-cadence presses.

## Session findings (2026-08-16, continued)

REPRODUCED + FIXED a second auto-deny path: the paste-burst flush. The
paste-burst detector holds a typed prompt (chars + trailing Enter within
the 30 ms join window) and emits ONE PasteInput on flush. When an
approval's readKey arms in that window — observed live at 80×24 with the
real provider: the env ceremony's first bash approval rendered just as
the prompt was submitted — the flush delivers the paste to the pending
readKey, which completes with it. The paste is not y/a/d, so the
approval auto-denies ("bash denied" with no answer char) AND the typed
prompt is lost (its Enter went into the paste). Byte-order evidence in
the COCOON_DEBUG_KEYS log: "[keys] event: PasteInput(79 chars)" printed
right after the approval prompt row rendered, with no keypress between.

Fix (commit f5029cc): `_onEventInner` never completes a pending readKey
with a PasteInput — the paste routes to the editor buffer (text
preserved), the readKey stays armed. The 21af54e fix covered only the
`_pending` overflow path; this is a second delivery path. Regression
test: "paste burst flush never answers a readKey (approval stays open)".

Still open: the steady-cadence "keys vanish for minutes" mode (T10
observation). Not reproduced across ~15 further runs (stub + real);
cadence keys during a running turn go to the queue by design, and an
open approval resolves on the first key that arrives while it pends.
Watch for it in the 80×24 corpus pass.

## Session findings (2026-08-16, continued #2)

REPRODUCED + FIXED the prompt-eating variant (the approval steals the
user's in-flight typing). Live repro at 80×24 with the real provider +
COCOON_DEBUG_KEYS ([readkey] armed/completed markers): the env
ceremony's first approval armed while the user was still typing their
prompt; the prompt's Enter was delivered to the approval's pending
readKey (the readKey-first routing) — answered as a deny (not y/a/d),
"bash denied", and the prompt was NEVER submitted (the session's user
message absent; the pasted text sat in the editor unsubmitted).

Fix (workflow_permission_asker + TuiConversationHost.askPermission): the
asker awaits `editor.pendingLine` (the in-flight readLine, new getter)
before arming its readKey — the approval's row stays visible and the
readKey arms only after the user's prompt submits. The editor's
readKey-first contract is unchanged (the spend-pause dialog and gates
still capture keys while a readLine pends); only the approval askers
defer. Regression test:
test/host/workflow_permission_asker_test.dart ("readKey waits while
the user is typing a prompt") fails without the fix.

THEN the wait itself deadlocked (found live, T5 at 80x24): the TUI
input loop ALWAYS sits in readLine (the next prompt arms the moment the
current one submits), so the asker waited on the always-pending EMPTY
readLine — every approval stalled behind the user's next prompt: 22 'y'
presses queued in the input, the approval never armed, the turn stalled
the whole watch. THE DEADLOCK IS THE TICKET'S "keys vanish for minutes"
SHAPE: keys accumulate silently in the input while the approval never
arms. Fixed (92b6292): the wait engages only when the pending readLine
carries unsent text (the user mid-typing); an empty pending readLine is
the idle input region. Regression test: "empty pending readLine does
not stall the approval (no deadlock)" fails without the buffer check.

Live-verified (80x24, real provider): 12/12 approval readKeys armed and
completed in lockstep with steady 8 s-cadence presses, zero denials —
the ticket's acceptance ("an open approval always consumes the next
keypress, including steady cadence") holds for every reproduced mode:

1. stale paste overflow answering a readKey — 21af54e (fixed earlier).
2. paste-burst flush answering a readKey (auto-deny + prompt loss) —
   f5029cc: `_onEventInner` never completes a readKey with a PasteInput.
3. the prompt's Enter answering the approval (prompt never submitted) —
   b27c6e1 + 92b6292: the approval askers defer to a readLine with
   unsent content.
4. the readLine-wait deadlock (the minutes-long vanish shape) — 92b6292.

CLOSED per close criteria: regression tests exist for 2-4, the root
suite (+540) and tina_console suite are green, and the live repros
(80x24 real provider + the corpus runs) pass from clean restarts.
