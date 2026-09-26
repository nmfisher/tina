# Goal mode (`--goal`) — headless loop-to-achieved

`tina --goal "<text>"` runs tina with **no user present** and no expectation
of input: it seeds the goal tracker with the text, runs agent turns until the
goal judge rules the goal **achieved**, and exits. It is the headless sibling
of the interactive `/goal` command (see [goal_command.md](goal_command.md)) —
same store, same middleware, same judge contract — wrapped in an unattended
loop.

`--prompt` stays one-shot: one turn, one answer. `--goal` loops.

```bash
tina --goal "make dart analyze pass" --max-goal-turns 15
```

## Flags

| flag | meaning |
|------|---------|
| `--goal <text>` | enter goal mode; seeds the goal tracker (same caps as `/goal`: non-empty, ≤500 chars) |
| `--max-goal-turns <n>` | turn cap before giving up (default 25; `0` = unlimited) |

Validation (`lib/config.dart`): `--goal` is mutually exclusive with `--prompt`
and `--workflow`; it cannot be combined with bare `--resume` (use `--resume
<id> --goal <text>` to resume with a goal); `--max-goal-turns` without
`--goal` is a rejected typo, not a silent no-op.

## Exit codes

| code | meaning |
|------|---------|
| 0 | the judge ruled the goal achieved |
| 1 | turn cap reached without an achieved verdict, **or** the judge failed to produce a parseable verdict 3 times in a row (an unverifiable goal must not loop forever) |
| 2 | a turn aborted for a non-permission reason (budget trip, provider error, watchdog, signal) — the same posture as an aborted `--prompt` run |
| 3 | a tool raised a permission ask: no user is present to approve it, and goal mode never answers for one |

## Permission posture — never widened by goal mode

`--goal` and `--yolo` are **different paradigms** and compose like any other
flags, but goal mode itself never grants anything:

- **Without `--yolo`**: the `HeadlessHost` auto-denies every ask (as it does
  for `--prompt`). The loop watches the host's ask feed; the first ask ends
  the run with exit 3 and a diagnostic naming the `tool:key` that was denied.
  Grant the rule via `--allow "TOOL:PATTERN"`, `[permissions]` config, or
  `--allow-regex` if the run should proceed — those are the ordinary,
  explicit ways to widen a headless policy.
- **With `--yolo`**: composition pre-widens the policy before the agent is
  built, so no ask ever surfaces — identical to a `--yolo --prompt` run. The
  loop's exit-3 path simply never fires.

Either way the goal loop adds no permissions of its own.

## How the loop works

1. **Seed** — after the shared headless setup (tracker hydration, provider,
   recorder, driver, watchdog — the same machinery a `--prompt` run builds),
   the store is seeded via `GoalStore.set(cid, text)` with the persist hooks
   already installed, so the goal lands in the session manifest exactly like
   a TUI `/goal`. The `GoalMiddleware` then injects the goal into every
   request; the agent always knows what it is working toward. Command
   dispatch is skipped: it is a user-input surface, and there is no user.
2. **Turn** — `GoalLoopRunner`
   (`packages/tina_app/lib/src/execution/goal_loop.dart`, pure and
   unit-tested) drives turns through the same driver a `--prompt` run uses.
   Turn 1's input is the goal text; later turns prepend a continuation nudge
   carrying the judge's evidence ("not yet achieved — <evidence>"), so the
   agent corrects course on facts.
3. **Judge** — after each completed turn, `judgeGoalCore`
   (`goal_judge.dart`) digests the transcript (`GoalJudgeDigest`: last 24
   messages, text verbatim, tool activity as `tool: name` markers, capped)
   and runs one read-only, tool-less standalone agent call. The judge never
   sees raw tool output and never runs anything. Parseable verdicts are
   recorded into the store (`recordVerdict`), so the manifest reflects
   progress; a failed call counts toward the 3-strike cap.
4. **Stop** — achieved → exit 0; ask detected → exit 3; aborted turn →
   exit 2; judge strikes exhausted → exit 1; cap reached → exit 1.

An aborted turn is never judged (the TUI judge holds the same rule): a
budget trip is not evidence of progress or failure.

## What goal mode does NOT change

Headless hosts already auto-resolve several human gates (plan approval
auto-grants, `ask_user` picks the first option, questions are refused).
Those precedents stand unchanged — goal mode is about *looping to a judged
goal*, not about widening what the agent may do. Permission asks remain the
hard stop (exit 3), because unlike those gates, a grant widens what the
agent may do to the machine.

## Tests

- `packages/tina_app/test/execution/goal_loop_test.dart` — the pure runner:
  achieved/cap/abort/ask/strike outcomes, unlimited mode, nudge content.
- `packages/tina_engine/test/host/headless_host_test.dart` — the
  `onPermissionAsk` hook fires before the denial.
- `test/config/cli_goal_flags_test.dart` — flag parsing and validation.
- `packages/tina_app/test/goals/goal_judge_test.dart` — the shared
  digest-based judge core.
