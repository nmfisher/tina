---
id: tin-v6tq
status: closed
deps: []
links: [tin-r2vd, tin-3x9v]
created: 2026-08-16T09:35:00Z
closed: 2026-08-16T19:10:00Z
type: bug
priority: 2
assignee: Nick Fisher
tags: [tui, input, startup-drain, notcurses, paste]
---
# Terminal capability replies arriving after the startup drain window paste into the editor

## Context

Found 2026-08-16 while hunting tin-3x9v: `tool/crash_replyburst.sh`
re-fires the tin-r2vd terminal-reply bundle *mid-run* (12 s / 30 s / 55 s
into a turn). The pane then shows the replies inside the editor as pasted
text:

```
> [Pasted text : 32 chars]yyyyyyyy[Pasted text : 4570 chars]yyyy...
```

That is expected for a burst long after startup — but it also pins down
*when* the protection ends. `StartupDrain`
(packages/tina_console/lib/src/backend/notcurses_input_backend.dart)
discards input only while `isDraining` holds:

- always for the first 150 ms (`minWindow`);
- never past 1000 ms (`maxWindow`);
- between the two, only while events keep arriving within **30 ms** of the
  last one (`idleThreshold`).

So the drain closes as soon as the reply stream pauses for 30 ms — not at
1 s. A terminal that answers notcurses' init queries in a slow or bursty
fashion (mux relay, cold SSH link, a terminal that walks a 256-entry OSC 4
palette with gaps) has its late replies delivered to the app as key events.
notcurses does not consume OSC 4/10/11 after init, so the bytes surface as
CharInput; the PasteBurstDetector joins the cluster into one `PasteInput`
and the editor renders "[Pasted text : N chars]". A following Enter submits
the garbage as a prompt.

`tmux_inject_replies.sh` documents "stray duplicates of the replies are
harmless" — for the *harness* they are not: a mid-run re-injection pollutes
the editor with ~4.5 KB of paste per burst (this is how the run above was
noticed).

## Repro

1. `tmux new-session -d -x 120 -y 40 -s leak` and start tina there with the
   usual init reply injection (so it comes up).
2. Wait for the first-load ceremony to finish (any point past 1 s of input
   idle).
3. Re-run `tool/tmux_inject_replies.sh leak`.
4. Observed: the editor gains a `[Pasted text : ~4570 chars]` chip; the
   capability replies were not discarded.
5. Expected: replies to notcurses' own init queries are dropped whenever
   they arrive, or at least while no user keystroke has been seen.

Deterministic variant: `tool/crash_replyburst.sh` (stub server, scenario
`crash_stream2`) — every run shows two 4570-char paste chips.

## Acceptance

- A reply burst arriving at any point before the first genuine user
  keystroke is discarded, not pasted.
- A regression test over `StartupDrain` (fake clock) covers the
  bursty-reply case: events with >30 ms gaps inside the first second are
  still drained.
- The harness note in `tmux_inject_replies.sh` stops claiming stray
  duplicates are harmless.

## Open design question (needs user decision)

The drain length is a UX trade-off, and the right point on it is a
judgment call rather than a defect fix:

- **Longer drain** (say idle gap 150 ms, max 3 s) eats a fast typist's
  first keystrokes on a warm start — the exact complaint the adaptive
  window was built to avoid (a fixed 150 ms window delayed the first
  key).
- **Shorter drain** (today's 30 ms idle / 1 s max) leaks a bursty or
  late reply stream into the editor.
- **Content-based drain** (keep discarding until the first key that
  can't be part of a reply) is not implementable at this layer: by the
  time the pump surfaces an event it is an id + modifiers pair, and a
  reply's printable bytes are indistinguishable from typing. notcurses
  gives no "this came from a reply" marker, and its bracketed-paste
  markers do not survive the pump (verified — see the dormant marker
  path in notcurses_input_backend.dart).

Real-world incidence is low: notcurses *blocks* on its init queries, so
on a healthy terminal the replies are consumed before the app ever runs.
The leak needs a reply to arrive after init has given up on it — a slow
mux relay or a terminal that answers late. It is trivially reproducible
with the harness (`tool/crash_replyburst.sh`), which is how it was
found.

Proposed default if the user wants it closed without a decision: raise
`idleThreshold` to 150 ms and `maxWindow` to 3 s, keeping `minWindow` at
150 ms, with a StartupDrain fake-clock test for the bursty case. Costs
at most 150 ms of first-keystroke latency on a warm start.

## Findings (2026-08-16, evaluating option 1 — raw-byte filtering)

### 1. Where bytes are read, relative to the pump

**Dart never reads an input byte.** The chain is:

```
tty fd ──read() inside libnotcurses──► ncinput{id,modifiers,evtype}
      ──notcurses_get_nblock()──► pump thread (native/src/input_pump.c:135)
      ──ring buffer──► Dart PumpedInput{id,modifiers,monotonicNs}
```

`NotcursesInputBackend` subscribes to `NotcursesInputPump.events`
(notcurses_input_backend.dart:280). The pump thread polls
`notcurses_inputready_fd(nc)` and dequeues with `notcurses_get_nblock` —
the bytes are already consumed and parsed by the time any tina code runs,
Dart *or* C.

### 2. Can tina hook the raw fd read before notcurses? **No.**

- `notcurses_options` (notcurses.h:1043) carries only `termtype`,
  `loglevel`, margins and `flags` — no input-fd override, no byte-injection
  entry point. The header states it outright (notcurses.h:1173): "All input
  is taken from stdin."
- The input API surface is `notcurses_get` / `notcurses_getvec` /
  `notcurses_get_nblock` / `notcurses_inputready_fd`. Nothing feeds bytes in.
- Reading the fd ourselves in the pump thread and filtering first would race
  notcurses' own read on the same descriptor and steal real keystrokes; the
  automaton would see truncated sequences. Not viable.
- `LD_PRELOAD`/`--wrap=read` interposition would work mechanically but is
  process-wide (file and socket reads too) and needs link-time changes.
- **The one real path**: tina already patches notcurses itself
  (`native/patches/notcurses-paste-events.patch` edits `src/lib/in.c`'s
  automaton, applied by `tool/build_notcurses.sh`). A raw-byte filter *could*
  live there. That is a true option-1 implementation, but it costs a
  notcurses rebuild per platform plus a committed static archive — not cheap,
  and not warranted given §5.

**Option 4 (init flag to skip/shorten negotiation): does not exist.** The
only input-related flag is `NCOPTION_DRAIN_INPUT` (0x0100), which means
"this client never reads input" — with it the TUI gets no keyboard at all
(already documented at notcurses_backend.dart:110). No flag skips or shortens
the init query phase.

### 3. Reply shapes and exact byte patterns

`ST` = `ESC \` (0x1b 0x5c); `BEL` = 0x07.

| Reply | Bytes |
|---|---|
| OSC 4 palette (×256) | `ESC ] 4 ; <idx> ; rgb:<4hex>/<4hex>/<4hex> ST` (or `BEL`) |
| OSC 10 / 11 fg, bg | `ESC ] 10 ; rgb:ffff/ffff/ffff ST`, `ESC ] 11 ; rgb:0000/0000/0000 ST` |
| DA1 | `ESC [ ? 62 ; c` (tmux sends `ESC [ ? 1 ; 2 ; 4 c`) |
| CPR | `ESC [ <row> ; <col> R` |
| DECRPM | `ESC [ ? 2026 ; 1 $ y`, `ESC [ ? 1016 ; 1 $ y` |
| XTMODKEYS | `ESC [ ? 1 ; 3 ; 256 S` |
| kitty kbd flags | `ESC [ ? 1 u` |
| kitty graphics (APC) | `ESC _ G i=1;OK ST` |
| XTGETTCAP (DCS) | `ESC P 1 + r <hex> ST` |
| XTWINOPS | `ESC [ 4;1;1;80;120 t`, `ESC [ 8;40;120 t` |

Termination differs by class and matters (see §5): OSC ends on `BEL`/`ST`;
DCS/APC/PM/SOS end on `ST` only; **CSI ends on a final byte 0x40–0x7E** after
parameter/intermediate bytes 0x20–0x3F.

### 4. What the pump actually delivers (measured)

`tool/reply_decode_spike.dart` runs tina's exact notcurses init and logs
every pump event. One run, three inputs:

| Input | Events | Span | Max gap | ESC events |
|---|---|---|---|---|
| Re-injected reply bundle (mid-run) | 4837 | 198 ms | 3 ms | 267 |
| Genuine 5400-byte bracketed paste | 5400 | 18 ms | 1 ms | **0** |
| Typed `a b c` / `o k` | 3 / 2 | — | — | 0 |

notcurses' automaton has no rule for OSC replies after init, so it emits the
leading `ESC` as a **standalone key event** and decodes the rest of the reply
as ordinary printable characters (the `yyyyyyyy` in the original repro is the
hex of `rgb:yyyy/...`). Distinct characters across the whole burst:
``$ + / 0-9 : ; ? P S [ \ ] a-f g r t u x y``.

**This overturns the ticket's "not implementable at this layer" claim.** A
reply is separable from typing *and* from pasting by two independent signals:
an `ESC` immediately followed by a sequence introducer (`] [ P _ ^ X`), and
burst-rate arrival. A genuine paste carries no `ESC` events at all —
notcurses consumes the `ESC[200~`/`ESC[201~` markers — so it cannot match.

### 5. Prototype

`packages/tina_console/lib/src/backend/reply_sequence_filter.dart` — pure,
time-parameterized, **not wired into `NotcursesInputBackend`**. Swallows
`ESC` + introducer runs, terminating per class. 11 tests in
`packages/tina_console/test/reply_sequence_filter_test.dart`.

Validated against the real captured streams
(`packages/tina_console/tool/validate_reply_filter.dart`):

- capture with a burst + typing: 9711 events in → 5 out (`abc`, `xy`);
- capture with a burst + a genuine 5.4 KB paste + typing: 10271 in → 5402
  out (the whole paste, verbatim, plus `ok`). Zero `ESC` passed.

The prototype's first version had a bug the real capture caught and the unit
tests missed: it only closed a reply on `BEL`/`ST`, so the CSI replies (which
end in a final byte, e.g. the `t` of `ESC[8;40;120t`) left it swallowing
forever — it ate the *next paste* too. Fixed with per-class termination and
pinned by two regression tests.

### 6. False-positive risk

- **Typing `ESC` then `]`**: needs both keys within 5 ms. Not hand-producible
  (two keystrokes are ≥50 ms apart). A slowly typed pair is delivered intact.
- **Genuine paste**: no `ESC` events, cannot match (measured, §4).
- **Paste of text that itself contains reply sequences** (a captured
  typescript, a `script` log): those runs would be dropped. Low incidence,
  and the same bytes are unwanted in an editor either way — flagged as an
  accepted trade-off, not a silent one.
- **Undecoded CSI key** (`ESC [ A`, an arrow): if notcurses ever failed to
  decode a real key it would surface as `ESC` + `[` + `A` and be swallowed
  (`A` is a valid final byte). Mitigated by aborting the swallow on any
  non-printable event, so Enter/Tab/Backspace are never eaten. Residual risk
  is low: arrow decoding is core notcurses functionality, and it is what
  prevents `ESC[A` from reaching us today.

### 7. Recommendation

Option 1 as specified (raw-byte filtering before notcurses) is **not
reachable** through the notcurses 3.0.17 API, and reaching it by patching
notcurses costs more than the bug warrants. Option 4 does not exist.

Recommend **option 5, event-layer shape filtering**: wire the validated
prototype into `NotcursesInputBackend._onPumpedInput`, ahead of the
paste-burst detector, keeping `StartupDrain` as-is for the init window. It
fixes the reported symptom (the burst pastes into the editor) with no
first-keystroke latency cost — the trade-off the drain-length debate could
not escape — and it is fully covered by tests plus the captured-stream
validator. Wiring it is a small, testable change; awaiting a go-ahead since
the ticket is tagged needs-user-decision.

## Implementation (2026-08-16, option 5 — user approved)

Wired in as recommended. `NotcursesInputBackend` now owns a
`ReplySequenceFilter` (`replySequenceFiltering: true` by default; pass
`false` for the old behaviour) and applies it to raw pump records in
`_onPumpedInput`, after the `StartupDrain` check and before the
paste-burst detector. The body of the old handler moved to
`_deliverPumpedKey` unchanged, so the paste-marker path and the explicit
paste buffer behave exactly as before.

Two details the prototype did not need, the wiring does:

- **Lone-ESC release.** The filter holds an `ESC` for `introducerWindow`
  (5 ms) to see whether an introducer follows. On an event-driven path
  nothing would ever release a genuine cancel ESC — the user presses ESC
  and nothing else. `isHoldingEscape` (added to the filter) arms a
  `introducerWindow + 1 ms` timer that flushes the held ESC into the normal
  path. Net cost of the whole feature for the ESC key: ~6 ms, on top of the
  ~31 ms the burst detector already adds to every keystroke on this path.
- **Explicit-paste bypass.** While a marker-delimited paste is open
  (`_explicitPaste != null`) records skip the filter: that content is
  known-genuine, and pasting text that contains `ESC ]` must not advance
  the filter's state machine.

### Verification

- Unit: 11 filter tests + 9 wiring tests in
  `packages/tina_console/test/notcurses_input_backend_test.dart` (`pump-path reply filtering`
  group) — burst swallowed at the backend level, typing/paste/ESC/Enter all
  delivered, the `>30 ms` bursty-gap acceptance case, marker bypass, and
  the `replySequenceFiltering: false` escape hatch. tina_console suite 697
  green, root suite 540 green.
- Live (`tool/verify_reply_filter.sh`, new, stub provider, one run):
  typing lands; a genuine 1500-char bracketed paste lands as one intact
  chip; a lone ESC does not eat following keys; the full reply bundle
  re-injected mid-run leaves **zero** chips and zero residue, and typing
  still lands after it; app alive.
- Live (`tool/crash_replyburst.sh`, the ticket's deterministic repro):
  prior-session panes show the symptom (`[Pasted text : 4570 chars]` ×2 per
  run); the post-fix run shows no paste chips and no reply bytes — only the
  harness's own `y` keys in the editor.
- Harness note in `tool/tmux_inject_replies.sh` updated again: a mid-run
  re-injection is now safe for the app (still useful as input-path load,
  which is why `crash_replyburst.sh` keeps firing it).

Residual trade-offs are unchanged from §6 and accepted: a paste of text
that itself contains literal reply sequences (a captured typescript) would
have those runs dropped, and an undecoded CSI key would be swallowed.
