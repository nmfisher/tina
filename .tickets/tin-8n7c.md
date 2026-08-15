---
id: tin-8n7c
status: open
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
