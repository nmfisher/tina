# Sweep status
Now:     200x50 corpus pass running (T1-T15); tin-v6tq evaluation reported
Next:    finish 200x50, then a fresh pass at 60x10; PR
Blocked: none
Ask:     tin-v6tq — option 1 (raw-byte filter) is unreachable via the notcurses
         3.0.17 API and option 4 (init flag) does not exist; a validated
         event-layer filter is prototyped and awaits a go-ahead to wire in.
         Plus the parked feature tickets below.
Last checkpoint: 2026-08-16 14:05 — tin-v6tq evaluated (option 1 rejected,
prototype validated), tin-3x9v hunted 4 more runs incl. a union harness (13
total, no crash); branch: 3 commits over PR 11's head

## This session

- **tin-v6tq (p2, needs-user-decision) — option-1 evaluation delivered**
  (user request 2026-08-16). Findings on the ticket:
  - Dart never reads an input byte; `notcurses_get_nblock` parses inside
    libnotcurses before the pump thread sees an `ncinput`. No input-fd
    override, no byte-injection API, no init flag to skip negotiation
    (`NCOPTION_DRAIN_INPUT` means "never read input"). Option 1 unreachable;
    option 4 does not exist.
  - Measured what the pump delivers (`tool/reply_decode_spike.dart`): a
    reply bundle = 4837 events / 198 ms / 267 ESC; a genuine 5400-byte paste
    = 5400 events with **zero ESC**; typing is isolated. This overturns the
    ticket's "content-based filtering not implementable at this layer" claim.
  - Prototype `ReplySequenceFilter` (NOT wired in) + 11 tests + a validator
    over the captured streams: burst swallowed, paste and typing verbatim.
  - Recommendation: wire it into `_onPumpedInput` ahead of the burst detector
    — fixes the symptom with no first-keystroke latency cost.
- **tin-3x9v (p1)** — new `tool/crash_union.sh` fires the reply burst + resize
  storm + key hammer simultaneously (both recorded crashes shared all the
  conditions at once). 3 runs alive, +1 gdb run under the real provider.
  13 hunt runs total, zero SIGSEGV. Queue saturation is now measured, not
  hypothetical: 4837 records against the pump's 256-slot cap.

## Open (hunted / not in play)

- tin-3x9v (p1) — keep open; crash_gdb.sh first if it recurs, then
  crash_union.sh. Full notes on the ticket.
- tin-p2sq, tin-g7rk, tin-c5nw, tin-y4qn, tin-r2vd, tin-j3mk — pre-existing,
  not in play per the brief.
- tin-1h8p, tin-80ll, tin-923l, tin-f5xt, tin-k9q3 — decided feature/proposal
  tickets from prior sessions, parked pending user prioritization.
- tin-v6tq — needs-user-decision (see Ask).

## Closed earlier

- tin-m2vq (p2) — rapid-resize row merge (PR 11).
- tin-4k8w, tin-6a2f, tin-8n7c, tin-7b3p, tin-uzo3, tin-m4qk and older — see
  git log.

---
## Corpus results

| Task | 120x40 (prev session) | 80x24 (last session) | 200x50 (this session) |
|------|----------------------|----------------------|----------------------|
| T1 | PASS | PASS | running |
| T2 | PASS | PASS | pending |
| T3 | PASS | PASS | pending |
| T4 | PASS | PASS | pending |
| T5 | PASS | PASS | pending |
| T6 | PASS | PASS | pending |
| T7 | PASS | no answer in watch | pending |
| T8 | PASS | PASS | pending |
| T9 | PASS | no answer in watch | pending |
| T10 | PASS | PASS | pending |
| T11 | PASS | PASS | pending |
| T12 | PASS | no answer in watch | pending |
| T13 | NO-SHOW | PASS | pending |
| T14 | PASS | not rerun | not rerun (scenario) |
| T15 | PASS | NOT RUN | pending |

## Notes

- corpus_sweep.sh now refuses to run when a prompt file is missing (a silent
  skip cost a session t15). All 15 prompt files present this session.
- ~/.tina/config is read-only mounted and already correct (deepseek /
  deepseek-v4-flash, key matches /secrets/use_deepseek.sh) — left as-is.
  Stub runs use HOME=/tmp/stubhome.
- Stub server: `dart run tool/stub_server.dart --port 8907 --scenario
  crash_stream2` (the harnesses expect 8907; the tool's default is 8787).
- tool/reply_decode_spike.dart must await (not sleep()) or the pump's
  NativeCallable.listener never fires — cost two dead runs before the
  isolate-blocking bug was spotted. Same for IOSink flush + writeln.
- Toolchain: /home/agent/dart-sdk (3.13.0) for all builds/tests.
