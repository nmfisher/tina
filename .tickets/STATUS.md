# Sweep status
Now:     tin-q4vz hunt 1 checkpointed — ANSI/VT path exonerated (pinned
         green in test/chat_paste_border_test.dart), comet ruled out;
         the corruption lives in the notcurses child-plane /
         native-scroll / busy-repaint path.
Next:    tin-q4vz (p2): notcurses-context repro (render_to_image-style
         harness) driving the paste corpus with busy toggling mid-stream;
         then fix. tin-w8dl (p2) still needs instrumentation — no
         deterministic repro yet.
Blocked: none
Ask:     Parked features awaiting prioritization: tin-1h8p, tin-80ll,
         tin-923l, tin-f5xt, tin-k9q3, tin-g7rk. Also: push the tin-g2w9
         commit now (fresh branch + PR) or hold until more fixes
         accumulate? (carried over; four unpushed fixes now sit locally —
         tin-g2w9, tin-h5nm, tin-k7tr, plus the q4vz pinning test.)
Last checkpoint: 2026-08-17 08:02 — root 543/543 green; tina_console
         722/722 green; tin-h5nm + tin-k7tr closed with live stub
         verification from clean restarts.

## This session

- **tin-h5nm (p2) closed.** Environment ceremony false success: a
  text-final agent turn counted as "Environment record updated" while
  ENVIRONMENT.md was never written, pinning the region fresh and
  re-running the ceremony (a provider round-trip) every launch. Fix:
  run() snapshots the record bytes and success additionally requires the
  record to advance (present on first load, content-changed on
  re-verify). Coordinator message reworded to "did not update
  ENVIRONMENT.md". 3 new tests; live stub repro both legs (warning
  branch, no tracking.json stamp, honest re-run on restart).
- **tin-k7tr (p3→closed) closed.** Resume-path reply fragment leak: the
  startup drain discarded records without feeding ReplySequenceFilter,
  so a sequence split across the drain boundary leaked its printable
  tail into the editor (`;154;rgb:afff/ffff/ff00`, 23 chars). Fix:
  drained records feed the filter (output discarded); _onDrainEnd
  flush-discards a held lone ESC so a drained Escape cannot replay
  stale. Both boundary-split regression tests fail on the unfixed
  backend; live --resume + inject legs clean, persisted bytes clean.
- **Seeds run: empty-dir first-run (clean — no findings), 5k paste +
  queue-during-execution.** The paste seed produced two tickets:
  - tin-q4vz — chat panel renders expanded paste rows without the left
    border (11 rows, survives repaint, ASCII-only reproduces); with
    CJK/emoji one row per section also drops a char (`long-token:` →
    `long-toke :`). Persistence unaffected.
  - tin-w8dl — one run in four the 6000-char paste arrived as 5412 and
    the following Enter didn't submit. Likely burst-detector split under
    load; needs instrumentation.
- Queued-message ordering during execution verified correct (3 messages,
  in order, one answer turn each).

## Open (hunted / not in play)

- tin-q4vz (p2) — paste-content rows lose left border; deterministic
  repro on the ticket.
- tin-w8dl (p2) — intermittent paste truncation + swallowed Enter; 1/4,
  hunt plan on the ticket.
- tin-3x9v (p1) — keep open; crash_gdb.sh first if it recurs, then
  crash_union.sh. Full notes on the ticket.
- tin-y4qn (p2) — pre-existing, not in play per the brief.
- tin-1h8p, tin-80ll, tin-923l, tin-f5xt, tin-k9q3 — decided
  feature/proposal tickets from prior sessions, parked pending user
  prioritization.

## Closed earlier

- tin-h5nm, tin-k7tr (this session, local commits).
- tin-g2w9 (p1) — torn-JSONL append repair (local commit, unpushed).
- tin-j3mk (p2) — teardown UAF: input pump joined before notcurses_stop
  on every stop path (in PR 13).
- tin-r2vd (p1) — notcurses init wait bounded for mute terminals (PR 13).
- tin-c5nw (p1) — global shortcuts cycle panels while an approval is
  open (PR 13).
- tin-v6tq (p2), tin-p2sq (p1) — PR 12.
- tin-m2vq (p2) — PR 11.
- tin-4k8w, tin-6a2f, tin-8n7c, tin-7b3p, tin-uzo3, tin-m4qk and older —
  see git log.

## Notes

- The tina-smoke container that originally surfaced tin-j3mk still owes
  one re-run on a docker-capable host; this sandbox has none. The
  MALLOC_PERTURB_ batch remains the in-sandbox stand-in.
- Under `dart run` the TUI needs ~8–11 s to first paint in this sandbox;
  when injecting reply bursts (tmux_inject_replies.sh), inject AFTER
  paint onset or the bytes land in the dart CLI's stdin, not tina's
  (tin-k7tr hunt note).
- gdb hunting lore (also on the tin-j3mk ticket): attach after the asset
  lib dlopens — pending breakpoints never resolve under `dart run`; a
  passed-through SIGTERM under an attached gdb kills the VM instead of
  reaching Dart's watcher, so exercise signal paths without gdb.
- `tool/crash_teardown.sh` drives the tin-j3mk shapes: TEARDOWN_MODE =
  term-burst | term-flood | term-idle | quit-burst. MALLOC_PERTURB_=170
  in the launching shell reaches the dart process (tmux server restarts
  per run and inherits it).
- ~/.tina/config is read-only mounted and already correct (deepseek /
  deepseek-v4-flash); stub runs use a fresh HOME with the stub config
  (port 8907 this session).
- Toolchain: /home/agent/dart-sdk (3.13.0) for all builds/tests; the
  shell's `dart` cannot run this repo's build hooks.
- tina_engine's package suite has one pre-existing failure in this
  sandbox: process_tree_test 'kills a backgrounded descendant…'. Root
  and tina_console suites are fully green (543 / 718).
