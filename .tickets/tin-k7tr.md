---
id: tin-k7tr
status: open
deps: []
links: [tin-v6tq, tin-r2vd, tin-3x9v]
created: 2026-08-17T05:58:00Z
type: bug
priority: 3
assignee: Nick Fisher
tags: [tui, input, reply-filter, resume]
---
# Resume path leaks a 23-char OSC-4 reply fragment into the editor

## Context

The tin-r2vd reply injection (harness workaround for mute terminals) sends
~4.8 KB of terminal replies. The tin-v6tq `ReplySequenceFilter` drops them
before they reach the editor — verified on the fresh-start path
(verify_reply_filter.sh). On the `--resume` path a fragment escapes:
`;154;rgb:afff/ffff/ff00` (23 chars — the tail of an OSC 4 palette reply)
arrives in the editor as a paste, shown as `[Pasted text : 23 chars]`.

2/2 reproductions on `--resume`, 0/1 on fresh start with the same
injection timing. Plausible mechanism: on fresh start the burst lands
inside notcurses' startup drain window (consumed as initdata); on resume
the session load delays the init queries, the burst lands after the drain
window, and the filter — which matches whole sequences — misses a
sequence split across the drain boundary (the `\e]4` prefix is consumed
elsewhere, the tail surfaces as input).

Real-terminal relevance: a reply that arrives fragmented around the
drain boundary on any startup path would leak the same way; the injection
just makes it deterministic.

## Repro

1. Fresh HOME + stub config, one turn, `/exit`.
2. Restart with `--resume <id>`, run `tool/tmux_inject_replies.sh <sess>`
   after alt-screen.
3. The editor shows `[Pasted text : 23 chars]` (submit it and read the
   persisted message to see the exact bytes).

## Session findings (2026-08-17)

3/3 reproductions on `--resume`, 0/1 on fresh start. The leaked fragment
differs per run — observed `;154;rgb:afff/ffff/ff00` (OSC 4 palette tail,
23 chars) and `d700/0000` (8 chars, DA1/DECRPM-style tail) — consistent
with a sequence split at the drain boundary rather than one fixed gap in
the filter. The leak also **prefixes real typed input**: a message typed
after resume persisted as `d700/0000post-crash message that must survive`
(tin-g2w9's live verification run). Corrupts user input silently — worth
bumping if the fresh-start path ever shows it too.

## Acceptance

- The full reply burst — including fragments split across the drain
  boundary — is dropped on both fresh-start and resume paths.
- A regression test at the `NotcursesInputBackend`/filter level covering
  a mid-sequence boundary split.
