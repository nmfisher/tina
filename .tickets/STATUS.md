# Sweep status
Now:     tin-g2w9 closed — torn-JSONL append repair landed locally (unpushed);
         batch = persistence-path seeds (truncated /resume, kill -9 mid-write,
         env ceremony, reply-filter resume leak).
Next:    tin-h5nm (p2, env ceremony false success) is the worst open bug;
         tin-k7tr (p3, reply fragment leaks into editor on --resume, 3/3).
         tin-3x9v stays watch-only. Empty-dir first-run + 5k paste seeds from
         this batch still unrun. One tina-smoke container re-run still owed on
         a docker-capable host (see Notes).
Blocked: none
Ask:     Parked features awaiting prioritization: tin-1h8p, tin-80ll,
         tin-923l, tin-f5xt, tin-k9q3, tin-g7rk. Also: push the tin-g2w9
         commit now (fresh branch + PR) or hold until more fixes accumulate?
Last checkpoint: 2026-08-17 06:10 — root 540/540 green; tina_engine at its
clean-tree baseline (1 pre-existing process_tree sandbox failure, identical
with the fix stashed); tin-g2w9 fix verified live end-to-end.

## This session

- **tin-g2w9 (p1, data loss) found, fixed, closed.** A crash mid-append
  leaves a torn last line; the loader skips it but the next append GLUES a
  fresh record onto it, so the following load silently drops both — the
  message sent right after a kill -9 restart is lost while exit reports
  "session saved: N messages". Fix: JsonlSessionStore.append repairs the
  unterminated tail through one RandomAccessFile handle (complete-record
  tail → newline; torn tail → truncate + WARNING). Gotcha found on the way:
  Dart's FileMode.append for RandomAccessFile seeks to EOF at open but does
  NOT force writes there — the handle must be re-positioned after truncate
  (first attempt zero-filled the gap). Two regression tests; live repro
  re-verified from clean restart.
- **tin-h5nm (p2) filed.** EnvironmentRunner.run() returns success on any
  text-final agent turn — ENVIRONMENT.md existence/change is never checked.
  Stub repro: 3/3 ceremonies printed "Environment record updated
  (ENVIRONMENT.md)" while the file was never written and tracking.json was
  stamped fresh; the ceremony then re-runs (a provider round-trip) on every
  launch, each time claiming success.
- **tin-k7tr (p3) filed.** On --resume the reply burst leaks a fragment
  past the tin-v6tq filter into the editor: `;154;rgb:afff/ffff/ff00` (23
  chars) and `d700/0000` observed, differing per run. 3/3 on resume, 0/1
  fresh start. It also prefixes real typed input (a persisted message read
  `d700/0000post-crash message…`), so it silently corrupts user input.
- Toolchain note: the shell's `dart` (/opt/flutter) cannot run this repo's
  build hooks (kernel 127 vs 138 — the hooks_runner cache is pinned to
  /home/agent/dart-sdk 3.13.0). Always invoke /home/agent/dart-sdk/bin/dart.

## Open (hunted / not in play)

- tin-h5nm (p2) — env ceremony false success; repro + fix direction on the
  ticket.
- tin-k7tr (p3) — reply fragment leak on resume; 3/3 repro.
- tin-3x9v (p1) — keep open; crash_gdb.sh first if it recurs, then
  crash_union.sh. Full notes on the ticket.
- tin-y4qn (p2) — pre-existing, not in play per the brief.
- tin-1h8p, tin-80ll, tin-923l, tin-f5xt, tin-k9q3 — decided
  feature/proposal tickets from prior sessions, parked pending user
  prioritization.

## Closed earlier

- tin-g2w9 (p1) — torn-JSONL append repair (this session, local commit).
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
  sandbox has none. The MALLOC_PERTURB_ batch from the prior checkpoint is
  the in-sandbox stand-in, not a replacement.
- gdb hunting lore (also on the tin-j3mk ticket): attach after the asset lib
  dlopens — pending breakpoints never resolve under `dart run`; a
  passed-through SIGTERM under an attached gdb kills the VM instead of
  reaching Dart's watcher, so exercise signal paths without gdb.
- `tool/crash_teardown.sh` drives the tin-j3mk shapes: TEARDOWN_MODE =
  term-burst | term-flood | term-idle | quit-burst. MALLOC_PERTURB_=170 in
  the launching shell reaches the dart process (tmux server restarts per
  run and inherits it).
- ~/.tina/config is read-only mounted and already correct (deepseek /
  deepseek-v4-flash); stub runs use HOME=/tmp/stubhome (or a fresh copy).
- Toolchain: /home/agent/dart-sdk (3.13.0) for all builds/tests.
- tina_engine's package suite has one pre-existing failure in this sandbox:
  process_tree_test 'kills a backgrounded descendant…' (verified identical
  with tin-g2w9 stashed). Root and tina_console suites are fully green.
