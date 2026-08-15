# The UI sweep loop

Instructions for an agent session driving the tina TUI in an
edit → run → observe → fix loop. If you were pointed here, this document
is your brief — read it fully before starting.

## What you're working on

`tina` is a Dart notcurses TUI for driving LLM coding agents (see
`ARCHITECTURE.md` — six packages; the app is the repo root, the agent
runtime is `packages/tina_engine`). Your job is an iterative loop: run
the TUI, probe it for UI annoyances / bugs / odd behaviour, reproduce
each finding as a test, fix it, re-verify.

## Harness

- Drive the TUI via tmux: `tmux new-session -d -x 120 -y 40`, then
  `tmux send-keys` for input and `tmux capture-pane -p -e` for the
  screen state (that's your screenshot — diff before/after).
- Sweep geometries: 80×24, 120×40, 200×50, and nasty ones (60×10),
  including resizes mid-render (`tmux resize-pane`).
- Restart per iteration in a fresh tmux session so runs are identical.
  tina's sessions live under `~/.tina/` — reset them for
  reproducibility, keep them when testing `/resume`.
- Two provider modes, use both:
  1. The real pinned provider (config below).
  2. A local stub server replaying canned SSE over the provider
     `base_url` override — deterministic replays of mid-stream aborts,
     very long lines, emoji/CJK, rapid tool calls. Zero tina code
     changes needed. Bugs found against the stub are replayable forever.

## Pinned model config

Write `~/.tina/config.toml` once and never pass model flags on the CLI:
top-level `provider`+`model` (main agent), `[regions] model` (region
agents), workflow model. Key comes from env (e.g.
`ANTHROPIC_API_KEY`). All subagents, region agents, and workflows must
resolve to the same pinned pair — if any surface lets a different model
slip through, that itself is a finding.

## Target workspace

Point tina at `examples/workspace/` — a purpose-built fixture (see its
README). Its "deliberate edge cases" are ON PURPOSE — do not fix
`naïve_cache.dart` (unicode filename is the point),
`broken_probe.dart` (syntax error is the point), `blob.bin` (invalid
UTF-8 is the point), etc. `tool/example_workspace.sh dirty|reset|status`
creates/clears a deterministic dirty git state there.

## Triage & tracking

Tickets are the sole work stack. All tickets live in **`.tickets/`**
(format and rules: `.tickets/README.md`) — one file per finding, filed
**the moment it's noticed** with repro notes, not when work starts.
`.tickets/STATUS.md` is the human-visible surface, rewritten (never
appended) at every checkpoint:

```markdown
# Sweep status
Now:     tin-xxxx — chat panel reflow on resize (fix in progress)
Next:    tin-yyy (p1, broken render), tin-zzz (p3, annoyance)
Blocked: tin-aaa — deps: [tin-bbb]
Ask:     tin-ccc — needs-user-decision: is ESC-during-prompt meant to cancel?
Last checkpoint: 14:20 — 3 closed, 2 open, suites green
```

### One queue, one in-flight fix

Work the worst open ticket (priority order: crash / data loss / terminal
left broken → rendering corruption → wrong behaviour → annoyance →
cosmetic). Never more than one fix in flight.

**Found bug A while fixing bug B:**

- Default: file A as a ticket now, finish B, then re-triage. Do not
  start A because you're "already here".
- A is trivial, one-line, and in code you're already editing: fix it —
  but as its own ticket and its own commit.
- A blocks verifying B (e.g. A breaks the harness itself): set
  `deps: [A]` on B's ticket, work A first. This is the only legitimate
  preemption.
- A is a different subsystem, needs a judgment call, or has no repro
  yet: file and park it.

### Close criteria

A ticket closes only when all three hold: a
`VirtualTerminal`/`FakeStdio` regression test exists; the root suite and
the touched package's own suite (`cd packages/<pkg> && dart test` — they
are separate) are green; the original repro passes from a clean
restart. Close = commit, one logical fix per commit.

### Decide alone vs. ask

- **Decide alone**: reproducible defect, local testable fix, doesn't
  change intended behaviour.
- **Ask — batched, never blocking**: plausibly-*intended* behaviour,
  UX judgment calls, keybinding/layout changes, fixes that need a new
  subsystem. Tag the ticket `needs-user-decision`, add it to STATUS.md's
  `Ask:` line, keep working other tickets, ask everything at the next
  checkpoint.
- **Ask immediately**: destructive/irreversible action, change to
  security-relevant behaviour (permission prompts, yolo paths),
  non-trivial API spend. Blocks rather than proceeds.

The principle: autonomous about "make the thing behave as designed",
consultative about "what is the design".

### Checkpoints

After each scenario batch: rewrite STATUS.md, ask the batched
questions, continue on unblocked work. Tickets + STATUS.md + git log
are the complete resumable state — the conversation is disposable;
after any context compaction, reconstruct from those three.

## Scenario seeds (start here, then invent)

- resize mid-stream / mid-permission-prompt
- paste 5k chars into the editor; queue messages during execution
- ESC cancel at each stage of a turn
- `/resume` with a truncated session file
- permission prompt for the fixture's unicode filename
- long tool output (`data/long_line.txt`)
- empty-dir first-run experience
- `kill -9` mid-write, then restart

Scripts you find yourself re-typing → save under `tool/`.

## Known state (don't rediscover)

- Recently fixed: git `ls-files` C-quoting dropped non-ASCII filenames
  from the index; `GraphTraversal` ignored `maxNodes` for abstract
  seeds; `tina_index` suite repaired to the six-package layout.
- `ARCHITECTURE.md` is current for layout but thin on `regions/`,
  `pipeline/`, and `composition/`.
- Useful non-interactive smoke path: `dart run bin/tina.dart --prompt
  "..."` (no TUI) for agent-loop bugs; `--backend ansi` if notcurses
  misbehaves under tmux.
- Check `.tickets/` before filing — existing open tickets describe
  known issues (e.g. Ctrl+G leaking into approvals, markdown rendering).
