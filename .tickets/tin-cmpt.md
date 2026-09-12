---
id: tin-cmpt
status: closed
deps: []
links: [tin-y0l0]
created: 2026-09-12T05:30:00Z
type: bug
priority: 2
assignee: Nick Fisher
tags: [token-budget, compaction, agent-loop, headless]
---
# Disabling the per-turn cap silently removes the spend-based compaction trigger

## Context

Found while driving tina-only sandbox runs on PR #49 with
`tina --yolo --max-turn-tokens 0 --max-session-tokens 0`.

Observed repeatedly: a single turn runs for tens of minutes to hours with no
edit and no commit, and the context grows until one compaction pass finally
fires very late:

```
--- compacting 166 messages ---
...
--- compacted 166 → 9 messages ---
```

Two runs are on record:
- one reached 166 messages before its first edit, ~1h and ~103 file-reading
  operations with zero edits
- another ran 3h09m (29 edits, 217 bash calls) before finishing a single fix

The compaction summary itself is **good** — it kept file:line anchors, key
findings, and even the useful test helper names. So the summary quality is not
the problem. The problem is *when* it fires and what is no longer forcing a
checkpoint.

## Root cause

Compaction has two triggers (`packages/tina_engine/lib/src/agent/agent.dart`,
around line 610):

```dart
final sizeTriggered = estimate > autoCompactThreshold;
final spendTriggered = !_turnSpendCompactFired &&
    budget?.turnSpendCompactTrigger() == true &&
    estimate > autoCompactThreshold ~/ 2;
```

The spend trigger is **disabled whenever there is no per-turn limit**:

`packages/tina_engine/lib/src/agent/token_budget.dart`, around line 227:

```dart
/// Null (no per-turn limit) → false: with no cap
/// there is no fraction to cross.
bool turnSpendCompactTrigger() {
  final limit = perTurnLimit;
  final grand = turnTotal + turnEstimated;
  if (limit == null || grand < (limit * kTurnSpendCompactRatio).ceil()) {
    return false;
  }
  return exceededLimit() == null;
}
```

So with `--max-turn-tokens 0`:

1. `turnSpendCompactTrigger()` is always `false` — the 50% rung
   (`kTurnSpendCompactRatio = 0.5`) never fires.
2. Only the absolute size trigger remains: `estimate > autoCompactThreshold`,
   and the default threshold is **120000** tokens (`lib/config.dart`, default
   for `auto-compact-threshold`).
3. The hard budget abort is also gone, because there is no cap to exceed.

Net effect: the two mechanisms that used to bound a long turn — the 50%-of-cap
compaction rung and the hard budget abort — are both removed by the same flag.
Nothing else forces a checkpoint. In practice the only thing that ever produced
an early commit in these runs was a budget abort.

This is a real interaction, not just a slow model: the flag that makes a run
"unlimited" also removes its early-context hygiene and its checkpoint pressure.

## Repro

```
tina --yolo --max-turn-tokens 0 --max-session-tokens 0 \
     --prompt '<a task that requires reading a dozen files>'
```

Observed: the turn keeps reading well past the point where the 50% rung would
have compacted, and no checkpoint or commit is produced until the turn is long
past any reasonable size.

## Acceptance

- The spend-relative compaction trigger does not depend on a hard cap being
  set. When no per-turn limit is configured, use an absolute spend baseline so
  a many-step turn still compacts at a sane point (for example, when
  `turnTotal + turnEstimated` crosses some fraction of `autoCompactThreshold`).
- A long turn with no edit and no commit produces a visible advisory, so the
  operator and the model both see that the turn is running without a
  checkpoint. (This overlaps the previously proposed step-budget advisory.)
- `--max-turn-tokens 0` still means "no hard abort" — the fix must not
  reintroduce a cap, only restore early compaction and the advisory.
- Test: with no per-turn limit, a turn whose spend crosses the chosen baseline
  compacts exactly once, and the once-per-turn latch still holds.
- Test: with a per-turn limit set, today's behaviour is unchanged (the 50% rung
  and the hard abort both still work).
