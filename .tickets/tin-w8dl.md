---
id: tin-w8dl
status: closed
deps: []
links: [tin-k7tr, tin-v6tq, tin-c5nw]
created: 2026-08-17T07:55:00Z
closed: 2026-08-18
type: bug
priority: 2
assignee: Nick Fisher
tags: [tui, input, paste, burst-detector]
---
# Large bracketed paste intermittently arrives truncated and swallows the next Enter

## Context

Found driving the "paste 5k chars" seed. A 6000-char bracketed paste
(`tmux load-buffer` + `paste-buffer`) reached the editor as
`[Pasted text : 5412 chars]` in one run — 588 chars silently missing —
and the Enter sent 1.5 s after the paste did **not** submit (the paste
was still sitting in the editor; the screen showed the ceremony's answer,
not a paste turn). Three other runs of the identical sequence delivered
all 6000 chars and submitted cleanly (persisted 5999/6000, trailing
newline trimmed).

588 does not match any character class in the body (360 non-ASCII, 90
ZWJ+VS16, 72 CJK), so this is not a per-glyph wide-char drop — it looks
like a burst split: PasteBurstDetector flushing a first burst before the
tail arrives, with the tail then lost or still buffered when the Enter
joins the pending burst (a pasted Enter must not submit — but here the
burst was already closed, so the Enter vanished instead). Candidate
mechanisms: the burst joinWindow expiring mid-paste under load (the
environment ceremony was streaming concurrently), or a pump-batch
boundary racing the detector's pending state.

Editor-visible data loss + a dead Enter = the user cannot tell anything
is wrong until the message is sent short.

## Repro (1/4 so far → DETERMINISTIC 2026-08-18)

1. Fresh HOME, stub provider, launch tina in `examples/workspace`
   120×40; wait ~11 s for paint.
2. `tmux load-buffer /tmp/paste5k.txt && tmux paste-buffer`.
3. Sleep 1.5 s, send Enter, sleep 5 s, capture.
4. Healthy: editor empty, paste turn in chat, `[Pasted text : 6000 chars]`
   during the paste. Unhealthy (observed once, with a reused HOME that
   already had a session): editor still holds
   `[Pasted text : 5412 chars]`, no paste turn.

### Deterministic repro (hunt 2, 2026-08-18)

The 1/4 intermittency was the **ceremony's approval arming in the paste
window** — `emoji_cjk` canned replies never let the environment agent
issue a tool call, so most runs had no prompt open. Scenario
`tool/stub/scenarios/w8dl_ceremony.txt` makes the ceremony's first reply
a `bash` tool call → the real permission policy prompts →
`editor.readKey(globalKeys: true)` arms at paint onset. Harness:
`tool/w8dl_hunt.sh` (fresh/reused HOME cycle, paste-path audit via
`TINA_PASTE_AUDIT_LOG`, classifier `tool/w8dl_classify.py`). UNHEALTHY
on the first run. Audit trail of the failure:

```
detector drain[expire]: PASTE chars=6108 events=6000        # paste intact
PasteInput dispatched: chars=6108 readKeyArmed=true         # → editor buffer
                                                            #  under an ARMED readKey
readKey ANSWERED by ControlKey (global=true)                # the +1.5s Enter
                                                            #  answered the approval
```

**Root cause (swallowed Enter + stranded paste):**
`LineEditor._onEventInner` completes an armed global readKey with any
non-paste event, but a `PasteInput` arriving while the readKey is armed
falls through to `_dispatchEvent` — into the editor buffer. The user's
next Enter then ANSWERS THE PROMPT (denyOnce — the "ceremony's answer"
on screen), not the editor line. The paste is stranded: every later
Enter goes to whatever prompt arms next. The host's askPermission guard
(tui_conversation_host.dart, "await pending") only protects the ARM
moment (a non-empty readLine delays arming) — a paste arriving AFTER
the prompt armed has no protection.

**Root cause (588-char truncation, the split variant):** when a
delivery-side >30ms stall splits the burst (the detector stamps events
with Dart delivery time, not the pump record's native monotonic ts),
the tail crosses the armed readKey as CharInputs: the first answers
the prompt, the rest land in `_pending` (10ms overflow window) and are
DROPPED by `readKey`'s `_pending.clear()` once the window expires.
Native pump and detector are lossless by construction; the loss is
entirely in the editor's modal-crossing paths. (6108 vs 6000 in the
audit is UTF-16 units — astral codepoints count 2; the editor displays
runes. Benign.)

Next hunt: instrument PasteBurstDetector counts (events in vs paste
chars out) under the crash_replyburst-style loop; try pasting while a
stub turn streams (ceremony or agent) to load the input path; check
whether the second burst-half is delivered as CharInputs that the
editor then shows appended (it was not, on the one occurrence).

## Acceptance

- Deterministic repro or instrumented counter proof of where the chars
  go; then a regression test at the backend/detector level (a burst with
  an internal gap wider than joinWindow must still deliver every char —
  as one paste or two, never dropped).
- The Enter-after-paste submit path stays reliable when the paste burst
  is fragmented.

## Fix (closed 2026-08-18)

`LineEditor` now HOLDS a `PasteInput` while a **global** readKey
(approval / gate prompt) is armed, and delivers it through the full
pipeline one microtask after the prompt's readKey completes — the mirror
of askPermission's arm-guard, which defers arming while a readLine has
unsent content. Scoped to global readKeys: a non-global readKey (an
overlay owning the screen) keeps the long-pinned paste-into-buffer
behavior (line_editor_test 'paste burst flush never answers a readKey'
still passes untouched). Chained prompts re-hold; `close()` drains any
still-held paste into the buffer so shutdown can't drop it. Never
dropped anywhere.

Post-fix modal semantics: with a prompt visibly open, the first Enter
answers the prompt (y/n/a/d — Enter maps to denyOnce in askPermission);
the paste then appears in the editor and the next Enter submits it
whole. Data can no longer strand or truncate.

Verification: root 600/600, tina_console 807/807; new
`test/paste_held_under_prompt_test.dart` (5 tests: hold+deliver+second-
Enter-submit, chained re-hold, split-paste two-halves-in-order, no-hold
after resolution, close-drains); deterministic repro 3/3 HEALTHY from
clean restarts (fresh, fresh, reused-home) at full 6108/6000 chars.

Left as accepted behavior (pre-analyzed, no ticket): the detector stamps
events with Dart **delivery** time, so a >30ms event-loop stall mid-paste
splits one paste into two PasteInputs. Post-fix that is benign — both
halves are delivered in order (tested); the editor shows two adjacent
placeholders. If that ever reads as an annoyance, the fix direction is
stamping the detector with the pump record's native `monotonicNanos`
(hybrid clock; see the hunt notes above for why expire() must share the
same clock).
