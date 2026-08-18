# Sweep status
Now:     tin-3x9v closed as cannot-reproduce — the host mandate's second
         item. Full investigation log on the ticket: 2 recorded crashes
         (2026-08-15), zero reproductions across ~50 runs on two tree
         generations (broad sweep, gdb real-provider, reply-burst,
         osc-stress, resize-storm, union, MALLOC_PERTURB_ teardown, and
         today's re-runs of union 3/3 + oscstress 2/2 on the current tree).
         Credibility argument: every crash correlate has since been fixed
         or fenced (8n7c vanish precondition, 4k8w/p8k2/b4n7/q4vz render
         hardening, r2vd+v6tq+k7tr reply environment, j3mk pump-join).
         Residual documented: pump-thread get_nblock vs main-isolate render
         stays the only native concurrency; notcurses 3.0.17 header makes no
         thread-safety statement; the union harness exercises it hard
         (4837 events vs the 256-slot queue) without faulting. Re-open on
         any native SIGSEGV — crash_gdb.sh first, then crash_union.sh.
         Stash triage done as part of the log: all six pre-PR-13 stashes
         inspected, none held 3x9v material (@{3}/@{4} were superseded j3mk
         iterations), SHAs recorded on the ticket, all dropped.
Next:    tin-9x4m (p3, /spawn picker empty for custom providers) or a fresh
         probe batch from the scenario-seeds list. No open bug tickets
         otherwise.
Blocked: none
Ask:     1) Push now (fresh branch + PR) or keep accumulating? EIGHT
         unpushed fixes sit locally — tin-g2w9, tin-h5nm, tin-k7tr,
         tin-q4vz, tin-p8k2, tin-b4n7, tin-w8dl, tin-y4qn — plus
         tests/tooling and the 3x9v closure.
         2) RESOLVED: the 2026-08-17 "work order" anomaly — the host
         confirmed the order (y4qn then 3x9v) in this session; it was
         executed as mandate, not injection. No .tickets/ write-access
         investigation needed.
         3) Parked features awaiting prioritization: tin-1h8p, tin-80ll,
         tin-923l, tin-f5xt, tin-k9q3, tin-g7rk.
Last checkpoint: 2026-08-18 03:30 — mandate complete: tin-y4qn closed
         (fixed + tested + live-verified), tin-3x9v closed CNR with full
         log; stashes pruned after triage.

## This session

- **tin-y4qn (p2) closed** (host-mandated first). Signal-chain audit found
  the focus gate in `session_controller.dart:_runTurn` (both edges) and the
  never-signaling sub-agent surface (`SubAgentScheduler`). Fix touches app +
  engine; mapping documented at the `HostInterface.setActivity` seam so
  every producer (turn loop, scheduler, workflow runs) states the same
  contract: busy ⇔ that conversation's turn is in flight, idle = static.
- **tin-3x9v (p1) closed CNR** (host-mandated second). See the ticket's
  closure section for the run table, the credibility argument, the residual
  native-concurrency note, and re-open conditions.
- **Async progress verified** (y4qn item 1): fire-and-forget turns,
  per-conversation queues, detached-but-buffering regions — pinned by
  "keeps progressing without focus" in the new test file.
- **Tooling added:** tool/y4qn_hunt.sh (deterministic live verifier: spawn
  side panel → long turn → cycle focus away → sample the border comet →
  settle → assert static) + stub scenario y4qn_busy (~20 s paced stream).
  Hunt lore: the config must use a BUILT-IN provider id (deepseek) with
  base_url overridden to the stub — see tin-9x4m; suppress the first-load
  environment ceremony by pre-seeding ENVIRONMENT.md (stale records do not
  auto-run) or the ceremony consumes stub steps; stub log lines are
  `turn=N`; never `pkill -f stub_server.dart` from a shell whose own
  command line contains the pattern — including via a heredoc — (self-kill,
  exit 144).
- **Side finding filed:** tin-9x4m — /spawn picker empty for custom
  providers; the overlay then swallows keys until Esc.
- STATUS anomaly (old Ask #2) resolved: the y4qn→3x9v order was confirmed
  by the host this session ("Execute") and carried out.
- Stash cleanup EXECUTED: all six pre-PR-13 stashes triaged (see tin-3x9v
  closure), SHAs recorded on the ticket, dropped. Stash list is empty.

## Open (hunted / not in play)

- tin-9x4m (p3) — /spawn picker empty for custom providers (new).
- tin-1h8p, tin-80ll, tin-923l, tin-f5xt, tin-k9q3, tin-g7rk — decided
  feature/proposal tickets, parked pending user prioritization.

## Closed earlier

- tin-3x9v (p1) — this session, CNR with full log.
- tin-y4qn (this session, local commit).
- tin-w8dl, tin-p8k2, tin-b4n7 (prior sessions, local commits).
- tin-q4vz, tin-h5nm, tin-k7tr (prior sessions, local commits).
- tin-g2w9 (p1) — torn-JSONL append repair (local commit, unpushed).
- tin-j3mk (p2), tin-r2vd (p1), tin-c5nw (p1) — PR 13.
- tin-v6tq (p2), tin-p2sq (p1) — PR 12.
- tin-m2vq (p2) — PR 11.
- tin-4k8w, tin-6a2f, tin-8n7c, tin-7b3p, tin-uzo3, tin-m4qk and older —
  see git log.

## Notes

- The tina-smoke container that originally surfaced tin-j3mk still owes
  one re-run on a docker-capable host; this sandbox has none. The
  MALLOC_PERTURB_ batch remains the in-sandbox stand-in.
- Under `dart run` the TUI needs ~8–11 s to first paint in this sandbox;
  inject reply bursts AFTER paint onset or the bytes land in the dart
  CLI's stdin, not tina's (tin-k7tr hunt note).
- Toolchain: /home/agent/dart-sdk (3.13.0); the shell's `dart` cannot run
  this repo's build hooks. `dart test` must run from the package dir
  (root for the app suite, packages/tina_console for its own).
- tina_engine's package suite has one pre-existing failure in this sandbox:
  process_tree_test 'kills a backgrounded descendant…'. Root and
  tina_console suites fully green.
- Stub lore: /tmp/stubhome carries the canonical stub config; a pristine
  copy lives at /tmp/w8dl_hunt/stub.config. tool/w8dl_hunt.sh and
  tool/y4qn_hunt.sh (re)start the stub per invocation — kill leftover
  stubs between sessions or they hold the port.
- Paste-path audit lore: set TINA_PASTE_AUDIT_LOG=<file> in the tina env;
  log lines are `w8dl <ms> ...`. Counts are UTF-16 units, not runes. The
  hunt wrapper can hang at exit holding the stub as a child (do_wait) —
  kill the wrapper, not the stub.
- Width-table lore (tin-q4vz/p8k2): three tables in play — ours
  (term_width.dart), notcurses', the terminal's. Ours must be ≥ the
  terminal's per rune. driftsAgainstRaster marks the rows where that gap
  can displace cursor-relative raster output — new emits must not chain
  unaddressed runs after them.
- Repro-tool lore (tin-p8k2): a filler with internal spaces defeats the
  damage chain — use unbroken tokens; stderr pollutes the pane under test;
  geometry 120×40 splits (chat plane 76 wide), and the pipe-pane capture
  must be cut at the completion sentinel.
