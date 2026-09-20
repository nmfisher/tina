---
id: tin-y9k2
status: open
deps: []
links: [tin-1h8p, tin-cmpt, tin-y0l0]
created: 2026-09-20
type: feature
priority: 1
assignee: Nick Fisher
tags: [yolo, limits, sandbox]
---

# `--yolo` disables the OS sandbox and every configurable budget

## Context

`--yolo` currently relaxes only the permission ask-gate (`allowAllByDefault`).
Every numeric cap and the OS sandbox still apply, so a user who opts into
"don't stop me" still gets stopped — by the token funnel, the spend ledger, the
step cap, and the sandbox. Precedence must be:

    explicit CLI flag > --yolo > config file > defaults

`--safe-mode` and explicit `--deny` rules keep outranking `--yolo` (already
true; regression tests exist).

## Enumeration — every budget/limit, and what `--yolo` does to it

1. **Bash OS sandbox** (`sandboxEnabled`, default ON).
   `--yolo` disables it. New `--sandbox` flag (negatable pair of
   `--no-sandbox`) lets explicit intent win: `--yolo --sandbox` keeps the
   sandbox ON. Pass-through reason strings must distinguish "disabled by
   `--yolo`" from the existing "explicitly disabled (--no-sandbox)".
2. **Turn / session / request token caps** (`--max-turn-tokens` 1,000,000 /
   `--max-session-tokens` 10,000,000 / `--max-request-tokens` 200,000).
   `--yolo` treats an unset flag as 0 = cap off. Explicit flag wins over yolo.
3. **Global spend ceiling + RPM throttle** (`--max-global-tokens` 50M default,
   `--requests-per-minute` off). Same treatment: yolo ⇒ off unless the flag
   (or config→flag default plumbing) explicitly sets them.
4. **Sub-agent token budget** (`--max-sub-agent-tokens` 2M). Same treatment.
5. **Step cap** (`--max-steps`, default 500). Becomes a normal limit option:
   0 = unbounded (accepted for everyone, not yolo-gated — it is explicit user
   intent). Switch `parsePositive` → `parseLimit` for it; update `/usage`.
   Sub-agents keep their own small default (25) — a parent with unbounded
   steps does not hand each scout an unbounded loop budget.
6. **Sub-agent depth / concurrency** (`--max-sub-agent-depth` 3,
   `--max-sub-agent-concurrency` 6). `--yolo` ⇒ unbounded (0). `AgentQuota`
   semantics change: `maxDepth <= 0` = unbounded (today 0 rejects EVERYTHING
   because `allowsDepth = depth < maxDepth`), `maxLive <= 0` = no semaphore
   cap.
7. **Attractor workflow-engine caps** (`max_steps` 200, `max_node_visits` 8,
   engine.dart). `max_node_visits` is the infinite-cycle guard for arbitrary
   user graphs and stays HARD (like the action cap below). `max_steps` is the
   same class of runaway guard but scales with the graph; lifting it under
   `--yolo` is consistent with this change — the workflow surface is off by
   default, so this only fires for `--enable-workflow --yolo` runs.

## Hard limits that survive `--yolo` (by design, documented)

- Engine **action cap** (`KMaxToolCallsPerTurn`, agent.dart): the code already
  says "--yolo can't extend it". Runaway backstop; untouched.
- Attractor **`max_node_visits`**: cycle guard; untouched.

## Out of scope (fault detection / UX, not budgets)

`streamIdleTimeout`, `requestTimeout`, `watchdogSeconds`,
`autoCompactThreshold`, `transportRetryAttempts`. These catch hangs and manage
context; they do not cap spend or capability.

## Evidence from the wild

2026-09-20: an agent run under `--yolo` (implementing this very change) aborted
with `[budget] per-turn token budget exceeded (1019224 > 1000000 ...)`. The 1M
turn cap fired during ordinary code reading. Under this change it would not
have. Exactly the failure mode this ticket removes.

## Acceptance

1. No `--yolo`: every default byte-identical (root + package suites green,
   unchanged).
2. `--yolo`: sandbox pass-through with a "disabled by --yolo" reason; token
   caps off; step cap unbounded; sub-agent depth/concurrency unbounded.
3. `--yolo --sandbox`: sandbox stays ON (explicit beats yolo).
4. `--yolo --max-turn-tokens 500000`: cap fires at 500k (explicit beats yolo).
5. `--yolo --safe-mode`: still read-only (safe mode dominance).
6. `--yolo --deny 'bash:rm *'`: deny still wins.
7. `[limits]` config-file values are ignored under `--yolo` (file < yolo),
   while no-`--yolo` runs still honor them.
8. `--max-steps 0` parses everywhere and means unbounded.
