---
id: tin-3x9v
status: open
deps: []
links: [tin-8n7c, tin-j3mk]
created: 2026-08-15T16:20:00Z
type: bug
priority: 1
assignee: Nick Fisher
tags: [tui, crash, approvals, notcurses, segfault]
---
# SIGSEGV mid-run: pressing a key at a stuck approval prompt crashes the TUI

## Context

Two occurrences (2026-08-15, 120×40 detached-tmux harness with the tin-r2vd
reply injection, after the tin-8n7c readKey fix):

1. Fresh session, environment-agent first-load ceremony, first approval
   showing; the TUI crashed to the shell with "Segmentation fault" without
   any keypress (the crash happened between the approval render and the next
   keystroke).
2. Same setup, an approval that had ignored ~50 'y' presses at 6 s cadence
   (the tin-8n7c vanish); a single 'y' after a 15 s pause produced
   "Segmentation fault" and the shell prompt — the keypress was consumed by
   the dead process (the 'y' echoed in the shell).

The crash is a native SIGSEGV (not a Dart exception): the pane shows the raw
"Segmentation fault" line and the shell prompt returns. Distinct from
tin-j3mk (teardown-after-quit); here the TUI is mid-run at a pending
approval.

## Repro

1. Launch tina in detached tmux with the reply injection.
2. Wait for an approval prompt (the env-agent ceremony produces them).
3. Press a key (or in some runs, press nothing — the crash comes on its own).
4. Observed: "Segmentation fault", shell prompt returns.

Not every approval crashes — most resolve normally; the crash correlates
with approvals that have been "stuck" (see tin-8n7c's vanish).

Refined repro (5 occurrences by 2026-08-15 17:25): the crash lands while the
agent's tool output is STREAMING — e.g. a bash heredoc write or `dart run`
with "Running build hooks..." in flight — and a keypress arrives at the same
time (the editor renders the typed char). The last render before the crash
is the approval row + the streaming output row; the next keystroke's render
segfaults. No core dump is produced (Dart VM handles SIGSEGV itself) and no
VM crash dump reaches stderr — the shell just prints "Segmentation fault".
The crash also occurred once with no keypress at all, sitting at an approval.

## Notes

The approval path is askPermission → chat.write prompt → editor.readKey
(tui_conversation_host.dart). A native crash on the readKey/input path with
a stale input state suggests the notcurses input pump or the input-backend
drain touching freed memory (j3mk's teardown race is the same area).

## Acceptance

- No native crash: a keypress at any approval state resolves or denies the
  approval; the process never segfaults mid-run.
- Regression coverage: repeated approval cycles with keys at various
  cadences stay alive (the crash is native, so the regression is a
  soak/repeat test in the TUI harness rather than a unit test).

## Session findings (2026-08-16)

Crash not reproduced this session: ~25 automated runs (stub + real provider)
covering the ticket's conditions — first-load ceremony streaming while an
approval pends, approval resolved with the pause pattern, keys hammered
through long streaming tool output (120-line bash stream), real-provider
refactor turn. No SIGSEGV in any run.

Two render-path fixes landed in the same area (tin-4k8w, closed): the
mid-stream shrink reconcile and the post-resize full re-emission — both
harden the streaming render path the crash shared. Re-open if the crash
recurs after these.

Harness artifacts for re-attempts: tool/stub/scenarios/crash_stream2.txt
(ceremony-paced stream + 120-line streaming bash call),
tool/crash_hunt.sh / tool/vanish_hunt.sh (key-hammer + steady-cadence
drivers), tool/crash_gdb.sh (gdb wrapper for a native backtrace when it
does reproduce).
