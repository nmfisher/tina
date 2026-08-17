---
id: tin-w8dl
status: open
deps: []
links: [tin-k7tr, tin-v6tq]
created: 2026-08-17T07:55:00Z
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

## Repro (1/4 so far)

1. Fresh HOME, stub provider, launch tina in `examples/workspace`
   120×40; wait ~11 s for paint.
2. `tmux load-buffer /tmp/paste5k.txt && tmux paste-buffer`.
3. Sleep 1.5 s, send Enter, sleep 5 s, capture.
4. Healthy: editor empty, paste turn in chat, `[Pasted text : 6000 chars]`
   during the paste. Unhealthy (observed once, with a reused HOME that
   already had a session): editor still holds
   `[Pasted text : 5412 chars]`, no paste turn.

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
