# Sweep status
Now:     PR 13 raised (fresh branch asb/ui-sweep-j3mk, off origin/main 8384f48)
         carrying tin-r2vd, tin-c5nw, tin-j3mk. Teardown re-verified under a
         faulting allocator (12 crash_teardown.sh runs, MALLOC_PERTURB_=170,
         all clean).
Next:    tin-3x9v stays watch-only. Pick from the parked feature/proposal
         tickets once prioritized. One real tina-smoke container re-run is
         still owed on a docker-capable host (see Notes).
Blocked: none
Ask:     Parked features awaiting prioritization: tin-1h8p, tin-80ll,
         tin-923l, tin-f5xt, tin-k9q3, tin-g7rk.
Last checkpoint: 2026-08-17 06:00 — suites re-confirmed green (root 540,
tina_console 715); PR 13 open; no crash in 12 perturbed teardown runs.

## This session

- **PR 13 raised** — the 3 unpushed commits (tin-r2vd, tin-c5nw, tin-j3mk)
  pushed to fresh branch asb/ui-sweep-j3mk via push_via_api.py and opened
  against main. origin/asb/ui-sweep still holds the stale pre-squash commits
  of PR 11; leave it alone.
- **tin-j3mk confirmation under a faulting allocator.** No container runtime
  exists in this sandbox (no docker/podman/socket), so the queued tina-smoke
  re-run can't execute here. Equivalent: glibc MALLOC_PERTURB_=170 (verified
  present in the dart process's environ) scribbles freed memory at free(),
  so a pump-thread read of the freed notcurses context would deref garbage
  instead of silently succeeding. tool/crash_teardown.sh, all four shapes
  (term-burst, term-flood, term-idle, quit-burst) x 3 runs = 12/12 clean.
  Suites re-confirmed: root 540/540, tina_console 715/715.
- push_via_api.py needed one retry — first attempt stalled on a dead HTTPS
  connection (urlopen has no timeout; killed at ~3 min). Content-addressed
  objects made the retry safe; branch created cleanly (17 blobs, 3 commits).

## Open (hunted / not in play)

- tin-3x9v (p1) — keep open; crash_gdb.sh first if it recurs, then
  crash_union.sh. Full notes on the ticket.
- tin-y4qn (p2) — pre-existing, not in play per the brief.
- tin-1h8p, tin-80ll, tin-923l, tin-f5xt, tin-k9q3 — decided
  feature/proposal tickets from prior sessions, parked pending user
  prioritization.

## Closed earlier

- tin-j3mk (p2) — teardown UAF: input pump joined before notcurses_stop on
  every stop path (in PR 13).
- tin-r2vd (p1) — notcurses init wait bounded for mute terminals (PR 13).
- tin-c5nw (p1) — global shortcuts cycle panels while an approval is open
  (PR 13).
- tin-v6tq (p2), tin-p2sq (p1) — PR 12.
- tin-m2vq (p2) — PR 11.
- tin-4k8w, tin-6a2f, tin-8n7c, tin-7b3p, tin-uzo3, tin-m4qk and older —
  see git log.

## Notes

- The tina-smoke container that originally surfaced tin-j3mk still deserves
  one re-run where a container runtime exists (the user's docker host); this
  sandbox has none. The MALLOC_PERTURB_ batch above is the in-sandbox
  stand-in, not a replacement for the allocator that actually faulted.
- gdb hunting lore (also on the tin-j3mk ticket): attach after the asset lib
  dlopens — pending breakpoints never resolve under `dart run`; a
  passed-through SIGTERM under an attached gdb kills the VM instead of
  reaching Dart's watcher, so exercise signal paths without gdb.
- `tool/crash_teardown.sh` drives the tin-j3mk shapes: TEARDOWN_MODE =
  term-burst | term-flood | term-idle | quit-burst. MALLOC_PERTURB_=170 in
  the launching shell reaches the dart process (tmux server restarts per
  run and inherits it).
- ~/.tina/config is read-only mounted and already correct (deepseek /
  deepseek-v4-flash); stub runs use HOME=/tmp/stubhome.
- Toolchain: /home/agent/dart-sdk (3.13.0) for all builds/tests.
