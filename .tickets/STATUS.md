# Sweep status
Now:     tin-j3mk closed — teardown UAF fixed (pump joined before
         notcurses_stop on every stop path). Queue empty of pickable bugs.
Next:    tin-3x9v stays a watch-only hunt (no repro in 13 runs); otherwise
         pick from the parked feature/proposal tickets once prioritized.
Blocked: none
Ask:     1) Push/PR: 3 local commits (tin-r2vd, tin-c5nw, tin-j3mk) are
         unpushed and origin/asb/ui-sweep has 3 stale pre-squash commits
         (already merged as PR 11). Raise a fresh-branch PR as in prior
         sessions? 2) Parked features awaiting prioritization: tin-1h8p,
         tin-80ll, tin-923l, tin-f5xt, tin-k9q3, tin-g7rk.
Last checkpoint: 2026-08-17 05:35 — tin-j3mk root-caused, fixed, and closed;
suites green (root 540, tina_console 715); no crash in 12 teardown runs.

## This session

- **tin-j3mk (p2, crash) — closed.** Emergency stop paths (SIGTERM/SIGHUP
  reaper, any error escaping the TUI run loop, zone guard) called
  notcurses_stop while the native input pump thread was still polling
  notcurses_get_nblock on the context being freed — the recorded SIGSEGV in
  notcurses_stdplane. Fix: NotcursesBackend.leaveAltScreen now disposes every
  input backend it handed out (joining the pump thread) BEFORE the platform
  stop; dispose is idempotent so the normal path is unchanged. Proof of
  ordering live under gdb (cocoon_input_pump_stop precedes notcurses_stop);
  5 regression tests; 12 teardown harness runs clean.
- **tin-3x9v (p1)** — untouched this session; the teardown work narrowed the
  native-thread surface it hunts over. Keep open, hunt on recurrence.

## Open (hunted / not in play)

- tin-3x9v (p1) — keep open; crash_gdb.sh first if it recurs, then
  crash_union.sh. Full notes on the ticket.
- tin-y4qn (p2) — pre-existing, not in play per the brief.
- tin-1h8p, tin-80ll, tin-923l, tin-f5xt, tin-k9q3 — decided
  feature/proposal tickets from prior sessions, parked pending user
  prioritization.

## Closed earlier

- tin-r2vd (p1) — notcurses init wait bounded for mute terminals.
- tin-c5nw (p1) — global shortcuts cycle panels while an approval is open.
- tin-v6tq (p2) — ReplySequenceFilter wired into the pump path (PR 12).
- tin-p2sq (p1) — malformed-args recovery (PR 12).
- tin-m2vq (p2) — rapid-resize row merge (PR 11).
- tin-4k8w, tin-6a2f, tin-8n7c, tin-7b3p, tin-uzo3, tin-m4qk and older —
  see git log.

## Notes

- gdb hunting lore (also on the tin-j3mk ticket): attach after the asset lib
  dlopens — pending breakpoints never resolve under `dart run`; a
  passed-through SIGTERM under an attached gdb kills the VM instead of
  reaching Dart's watcher, so exercise signal paths without gdb.
- `tool/crash_teardown.sh` (new) drives the tin-j3mk shapes: TEARDOWN_MODE =
  term-burst | term-flood | term-idle | quit-burst.
- The tina-smoke container that originally surfaced tin-j3mk is worth one
  re-run at the next checkpoint batch to confirm the fix on the allocator
  that actually faulted (this host's glibc keeps freed pages mapped).
- ~/.tina/config is read-only mounted and already correct (deepseek /
  deepseek-v4-flash); stub runs use HOME=/tmp/stubhome.
- Toolchain: /home/agent/dart-sdk (3.13.0) for all builds/tests.
