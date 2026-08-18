# Sweep status
Now:     tin-y4qn closed — the panel busy cue (border comet) tracked FOCUS,
         not activity. `SessionController._runTurn` gated both edges of the
         `setActivity` signal on `identical(s, active)`: a turn ending while
         its panel was unfocused never cleared the cue (idle panel animated
         forever — the ticket's report), and a turn starting unfocused (queue
         drain, workflow injection) never raised it. Delegated sub-agent
         panels never signaled at all (their turns run via the scheduler's
         own agent.run, not the turn loop). Async progress itself was sound —
         verified + pinned by test. Fix: unconditional raise/clear at turn
         start/end + scheduler-driven cue for panelized jobs; the canonical
         activity-state mapping is documented on HostInterface.setActivity.
         Repros written first (all failed pre-fix): app-level harness
         (real Screen/PanelManager/coordinator/SessionController over
         FakeStdio) + engine scheduler test. Root suite green, tina_console
         745/745, tina_engine green except the documented pre-existing
         process_tree sandbox failure; analyze 30→30 (zero new). Live:
         tool/y4qn_hunt.sh (new stub scenario y4qn_busy) — HEALTHY,
         busy-unfocused 2/2/2 comet samples, idle-unfocused 0/0, queued turn
         ran while unfocused.
Next:    tin-3x9v (p1) — close as cannot-reproduce with a full investigation
         log per the host mandate: crash_gdb.sh path first if it recurs, the
         pre-PR-13 stashes hold crash material (one names 3x9v), triage and
         prune them as part of the log. Then tin-9x4m (p3) and a fresh probe
         batch from the scenario-seeds list.
Blocked: none
Ask:     1) Push now (fresh branch + PR) or keep accumulating? EIGHT
         unpushed fixes sit locally — tin-g2w9, tin-h5nm, tin-k7tr,
         tin-q4vz, tin-p8k2, tin-b4n7, tin-w8dl, tin-y4qn, plus
         tests/tooling.
         2) RESOLVED: the 2026-08-17 "work order" anomaly — the host
         confirmed the order (y4qn then 3x9v) in this session; it was
         executed as mandate, not injection. No .tickets/ write-access
         investigation needed.
         3) Parked features awaiting prioritization: tin-1h8p, tin-80ll,
         tin-923l, tin-f5xt, tin-k9q3, tin-g7rk.
Last checkpoint: 2026-08-18 03:05 — tin-y4qn closed; root suite green,
         tina_console 745/745, tina_engine 561/562 (pre-existing sandbox
         failure only); live hunt HEALTHY.

## This session

- **tin-y4qn (p2) closed** (host-mandated first). Signal-chain audit found
  the focus gate in `session_controller.dart:_runTurn` (both edges) and the
  never-signaling sub-agent surface (`SubAgentScheduler`). Fix touches app +
  engine; mapping documented at the `HostInterface.setActivity` seam so
  every producer (turn loop, scheduler, workflow runs) states the same
  contract: busy ⇔ that conversation's turn is in flight, idle = static.
- **Async progress verified** (ticket item 1): fire-and-forget turns,
  per-conversation queues, detached-but-buffering regions — pinned by
  "keeps progressing without focus" in the new test file.
- **Tooling added:** tool/y4qn_hunt.sh (deterministic live verifier: spawn
  side panel → long turn → cycle focus away → sample the border comet →
  settle → assert static) + stub scenario y4qn_busy (~20 s paced stream).
  Hunt lore: the config must use a BUILT-IN provider id (deepseek) with
  base_url overridden to the stub — see tin-9x4m; suppress the first-load
  environment ceremony by pre-seeding ENVIRONMENT.md (stale records do not
  auto-run) or the ceremony consumes stub steps; stub log lines are
  `turn=N`; never `pkill -f stub_server.dart` from an interactive shell
  whose own command line contains the pattern (self-kill, exit 144).
- **Side finding filed:** tin-9x4m — /spawn picker empty for custom
  providers; the overlay then swallows keys until Esc.
- STATUS anomaly (old Ask #2) resolved: the y4qn→3x9v order was confirmed
  by the host this session ("Execute") and carried out.
- Stash cleanup note carried over: FIVE pre-PR-13 stashes remain — one
  mentions tin-3x9v crash material; inspect as part of the 3x9v log, prune
  once triaged.

## Open (hunted / not in play)

- tin-3x9v (p1) — next per the mandate: full investigation log, close as
  cannot-reproduce if it stays dead. crash_gdb.sh first if it recurs.
- tin-9x4m (p3) — /spawn picker empty for custom providers (new).
- tin-1h8p, tin-80ll, tin-923l, tin-f5xt, tin-k9q3, tin-g7rk — decided
  feature/proposal tickets, parked pending user prioritization.

## Closed earlier

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
