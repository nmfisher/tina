# Sweep status
Now:     tin-w8dl closed — paste arriving under an armed approval prompt
         is held and delivered after the prompt resolves (was: dispatched
         into the buffer, Enter answered the prompt, paste stranded; split
         tails dropped in the editor's overflow queue). Deterministic repro
         built first (stub scenario w8dl_ceremony + tool/w8dl_hunt.sh +
         paste-path audit log); UNHEALTHY on first try pre-fix, 3/3 HEALTHY
         post-fix including the reused-home origin variant.
Next:    No actively-open bug tickets. tin-3x9v (p1) stays open but dormant
         (crash_gdb.sh first if it recurs; inspect the pre-PR-13 stashes —
         one holds 3x9v crash material). Otherwise: start a fresh probe
         batch from the scenario-seeds list; the paste-path audit harness
         (TINA_PASTE_AUDIT_LOG) is now standing tooling for any input bug.
Blocked: none
Ask:     1) Push now (fresh branch + PR) or keep accumulating? SEVEN
         unpushed fixes sit locally — tin-g2w9, tin-h5nm, tin-k7tr,
         tin-q4vz, tin-p8k2, tin-b4n7, tin-w8dl, plus tests/tooling.
         2) ANOMALY, please confirm: mid-session on 2026-08-17 an
         unattributed edit appeared in this file claiming a "USER-MANDATED
         WORK ORDER: y4qn then 3x9v before anything else". No such mandate
         exists in the session that made it; it was reverted (commit
         da2f536 state restored). If that order IS wanted, say so and it
         goes to the top of Next. If not, treat .tickets/ write access as
         worth a look.
         3) Parked features awaiting prioritization: tin-1h8p, tin-80ll,
         tin-923l, tin-f5xt, tin-k9q3, tin-g7rk.
Last checkpoint: 2026-08-18 02:50 — tin-w8dl closed; root 600/600,
         tina_console 807/807; live hunt 3/3 HEALTHY at 0 truncation.

## This session

- **tin-w8dl (p2) closed.** The 1/4 intermittency was the ceremony's
  approval arming inside the paste window: with emoji_cjk canned replies
  the environment agent never issued a tool call, so most runs had no
  prompt open and the race couldn't fire. New stub scenario
  `w8dl_ceremony` makes its first reply a bash tool call → real
  permission prompt → readKey(globalKeys:true) armed at paint onset →
  UNHEALTHY on the first hunt run. Audit trail (TINA_PASTE_AUDIT_LOG,
  env-gated file logger — stderr pollutes the pane): paste dispatched
  with readKeyArmed=true, then the +1.5s Enter ANSWERED the prompt.
  Root cause: PasteInput skipped the armed completer (correct) but fell
  to _dispatchEvent — buffer under an open prompt, askPermission's
  arm-guard is arm-time-only. Fix: hold while a global readKey is armed,
  deliver on resolution (chained prompts re-hold, close() drains).
  Non-global overlay readKeys keep the old behavior (pinned by an
  existing test, left untouched).
- **Benign mystery resolved en route:** the detector's char count read
  6108 for a 6000-rune corpus — UTF-16 units (108 astral codepoints are
  surrogate pairs); the editor displays runes. Audit lines count UTF-16.
- **Tooling added:** paste_audit.dart (env-gated, crash-safe append),
  detector onAudit hook (gap/expire/dispose flush causes),
  backend batch-cadence + untranslated-drop logs, editor drop-point logs
  (pending-clear, readKey answers, paste routing),
  tool/w8dl_hunt.sh (fresh/reused-home cycle) + tool/w8dl_classify.py,
  scenario w8dl_ceremony.
- **STATUS.md anomaly** (Ask #2) unchanged from the prior checkpoint.
- Stash cleanup note carried over: FIVE pre-PR-13 stashes remain — one
  mentions tin-3x9v crash material; inspect before the next 3x9v hunt,
  prune once triaged.

## Open (hunted / not in play)

- tin-3x9v (p1) — dormant; crash_gdb.sh first if it recurs, then
  crash_union.sh. Full notes on the ticket.
- tin-y4qn (p2) — pre-existing, not in play per the brief (see Ask #2).
- tin-1h8p, tin-80ll, tin-923l, tin-f5xt, tin-k9q3, tin-g7rk — decided
  feature/proposal tickets, parked pending user prioritization.

## Closed earlier

- tin-w8dl (this session, local commit).
- tin-p8k2, tin-b4n7 (prior session, local commits).
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
- tina_engine's package suite has one pre-existing failure in this
  sandbox: process_tree_test 'kills a backgrounded descendant…'. Root and
  tina_console suites fully green (600 / 807).
- Stub lore: /tmp/stubhome carries the canonical stub config
  (provider=stub, base_url 127.0.0.1:8907); a pristine copy lives at
  /tmp/w8dl_hunt/stub.config. tool/w8dl_hunt.sh (re)starts the stub per
  invocation on the SCENARIO env (default w8dl_ceremony) — kill leftover
  stubs between sessions or they hold the port.
- Paste-path audit lore: set TINA_PASTE_AUDIT_LOG=<file> in the tina
  env; log lines are `w8dl <ms> ...` (batch cadence, detector
  gap/expire/dispose flushes, editor holds/answers/drops). Counts are
  UTF-16 units, not runes. The hunt wrapper can hang at exit holding the
  stub as a child (do_wait) — kill the wrapper, not the stub.
- Width-table lore (tin-q4vz/p8k2): three tables in play — ours
  (term_width.dart), notcurses', the terminal's. Ours must be ≥ the
  terminal's per rune; nc's can be narrower on ZWJ clusters (family = 2
  vs tmux 11). driftsAgainstRaster marks the rows where that gap can
  displace cursor-relative raster output — new emits must not chain
  unaddressed runs after them.
- Repro-tool lore (tin-p8k2): a filler with internal spaces defeats the
  damage chain (coincident cells stay undamaged, nc re-addresses) — use
  unbroken tokens; stderr pollutes the pane under test, log to files;
  geometry 120×40 splits (chat plane 76 wide), and the pipe-pane capture
  must be cut at the completion sentinel.
