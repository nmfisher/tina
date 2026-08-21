# Tina improvements log — recursive-improvement run, 2026-08-20

Running log of bugs found + improvements I would make to tina while driving it
(NVIDIA NIM `meta/muse-glimmer-30b`) to implement a session-wide
requests-per-minute rate limit in this repo. Newest entries at the bottom.

## Setup observations (pre-run)

1. **Model id discovery friction.** `meta/muse-glimmer-30b` is not in the NIM
   descriptor's static catalog, and there is no headless way to list a
   provider's models (`/model` picker is TUI-only; `listsRemoteModels` fetches
   only inside the TUI). I had to curl the endpoint out-of-band. A
   `tina --models <provider>` CLI (or `--prompt /models`) would remove the
   guesswork for scripted/headless use.
2. **Permission-classifier friction was environmental, not tina's fault** —
   but it did surface that every credential path (env var, `~/.tina/config`)
   is all-or-nothing: no `--api-key` flag for a one-shot run without touching
   config state. A `--api-key` flag (or `TINA_API_KEY`) would make ephemeral
   drives like this one cleaner.

## Round 1 — first task run

**Outcome: aborted by tina itself.** The agent explored correctly (ls →
AGENTS.md → ARCHITECTURE.md → config.dart → user_config.dart → spend_ledger →
metering_provider → provider_rate_limit → app_composition → bin/tina.dart —
exactly the right files for the RPM feature), made 26 requests over ~12
minutes, wrote nothing, and died with:

```
[budget] per-turn token budget exceeded (1037998 > 1000000).
Aborting to prevent runaway cost. Raise with --max-turn-tokens.
```

3. **BUG (fixed): no mid-turn auto-compact.** Auto-compact existed but only
   as a *between-turns* pass in the interactive `SessionController._runTurn`
   (`lib/session_controller.dart:462`). The headless `--prompt` path calls
   `agent.run` directly, and even interactively nothing compacts *within* a
   turn. A long autonomous turn accumulates tool results (round 1's requests
   grew 11K → 253K chars), re-sends the whole history per step, and dies at
   the 1M per-turn ceiling while making perfectly good progress.
   **Fix:** mid-turn auto-compact in the engine (`Agent.run`): when the next
   request's estimate exceeds `--auto-compact-threshold` (default 120K),
   summarize the older history in place and continue — keeping the trailing
   messages verbatim, splitting on an assistant-message boundary so no
   tool_use/tool_result pair is ever severed; failed compactions are gated to
   one attempt per 3 steps; unsplittable histories don't consume the gate.
   Wired from `Config` via `buildAgent` so headless/interactive/sub-agent
   paths all get it. Tests: engine mid-turn group (3) + compact
   preserveRecentMessages group (2) + app wiring test (1).
4. **Headless UX: no final prose from the agent.** muse-glimmer went 30+
   tool calls without one user-visible sentence (stdout had zero assistant
   text — only `→ tool` lines). tina could nudge chatty-tooling models with a
   system-prompt note, or the headless host could print a turn summary at
   end-of-run. (Not fixed this round — model behavior, borderline tina bug.)
5. **Budget-trip abort discards the session's forward progress silently.**
   The abort notice goes to stderr and the process exits 0 (!) — a script
   driving tina can't tell the turn failed without parsing stderr. Exit code
   should be non-zero when a turn aborts (also for provider errors).
6. **grep tool scans binary/asset dirs** (`examples/workspace/assets/*.png`
   warnings) — noisy in stderr; a default ignore for binaries (or
   `.gitignore`-aware skipping) would clean long greps. (Cosmetic.)
7. **Session persistence on abort worked well** — the full exploration
   history was persisted, so `--resume` can continue the task after the fix.
   (Positive note, worth keeping.)

## Round 1.5 — resume attempt, second bug

**Outcome: crash.** `tina --resume 20260820-025935-1462` (the exact id round 1
printed as its resume hint) died with `Bad state: Session not found` — the
session had actually been persisted under a different id
(`20260820-031242-a714`, minted at first-write time 03:12:42, not turn start
02:59:35).

8. **BUG (fixed): the headless resume hint pointed at a nonexistent session.**
   `resolveSession` pre-allocates a session id at startup and `bin/tina.dart`
   prints it, but the session is created lazily at first write by
   `SessionRecorder._lazyInit` → `store.createSession()`, which **mints its
   own id** and silently discards the pre-allocated one. Every fresh headless
   run printed a resume command that couldn't work.
   **Fix:** `SessionStore.createSession` gained an optional `sessionId`
   param; `JsonlSessionStore` honors it (minting fresh only on collision),
   the recorder passes its pre-allocated id through, and the headless exit
   prints the recorder's post-flush id. Tests: store honors id + collision
   fallback; two existing tests that had pinned the mint-fresh behavior were
   updated to the new contract.

## Round 2 — resume with both fixes in

**Outcome: budget trip again** (1,032,887 > 1,000,000, after 15 requests) —
but the resume-hint fix is verified working (`resume: tina --resume
20260820-031242-a714` now resolves). Wire log shows why mid-turn auto-compact
never fired: every request estimated 63–69K tokens, under the 120K
compaction threshold the entire time. The per-turn budget counts CUMULATIVE
usage (steps × re-sent context), which crossed 1M while no single request
was ever "large".

9. **Design gap (would make): spend-aware auto-compact.** Compaction
   currently keys on single-request size only. Because tina's per-turn
   budget counts cumulative usage, a many-step turn on a mid-size context
   (65K × 15 = ~1M) trips the ceiling with compaction never triggering. A
   turn-spend-fraction trigger (e.g. compact when turnTotal crosses ~50% of
   the per-turn cap AND the estimate is above a floor) would shrink every
   subsequent request and stretch the cap ~3× for exactly the runs that need
   it — long autonomous tasks on cheap models. Not fixed this run (the
   designed `--max-turn-tokens` knob is the documented remedy); logged as
   the improvement I would make next.
10. **Headless bash-denial flail.** The agent tried `cd … && dart test`,
    `ls /workspace`, `which dart` — all outside my `--allow` patterns — and
    burned 8 calls retrying variants instead of switching to the (default-
    allowed) `ls` tool or the `git` tool. The refusal hint on stderr is
    excellent (`--allow "bash:ls /workspace"`), but the tool RESULT the
    model sees should carry the same remediation (exact rule + "or use the
    ls tool") so the model self-corrects instead of re-trying blind.
11. **Small-model steering: prompt nudge exists and is ignored.** Correction
    from round 3's wire log: the system prompt ALREADY says "Prefer the
    dedicated read-only tools (ls, stat, which, glob, grep, search, git)
    over bash for inspection and lookup" — muse-glimmer flouted it anyway.
    Prose steering doesn't reach small models; the remedy that would is #10
    (put the exact `--allow` rule and native-tool suggestion in the deny
    tool-result itself, where the model must read it to continue).

## Round 3 — raised budget, broadened allows, task completed

**Outcome: success, exit 0.** With `--max-turn-tokens 8000000` and bash
allows matching the shapes the model actually reaches for (`bash:cd *`,
`bash:ls *`, `bash:which *`, `bash:pwd`), the agent ran BOTH suites —
engine (`packages/tina_engine`: 689 passing) and root (643 passing) — and
closed with an accurate written summary of the RPM feature (token bucket in
`SpendLedger.acquireRequestSlot`, session-wide enforcement in
`MeteringProvider.send`, CLI > `[limits]` config precedence, shared ledger
across main/sub-agent/workflow providers, seed/merge on resume and fleet
joins). It also confirmed no code gaps: the feature was already complete,
which matches my pre-run verification of main.

12. **Both prior fixes verified under load.** Mid-turn auto-compact: idle
    this round (contexts stayed ~65K est. tokens — under the 120K
    threshold, as designed). Resume-id fix: the run resumed
    `20260820-031242-a714` and exited printing the same id it actually
    held. No regressions in either suite.
13. **The agent's own closing offer beat my prompt's.** Unprompted, it
    suggested a multi-agent fan-out integration test under a tight RPM cap
    and doc tweaks — good instinct; a headless agent closing with concrete
    follow-up options (rather than just "done") is worth encouraging in
    the main identity. (Positive note.)
14. **Headless final-prose problem solved by prompting alone** (contrast
    #4): asking for "a short written summary as your final message" in the
    `--prompt` yielded exactly that. A `--require-summary` headless default
    (or appending that instruction automatically when `--prompt` runs)
    would make round-3-quality output the norm.

## Epilogue — the feature protecting its own provider

NIM's hard ceiling is 40 RPM, so the driver-side rule from here on is to
launch every tina run with `--requests-per-minute 30` — the feature
dogfooding itself as the guarantee. Verified live with a deliberately
tight throttle (`--requests-per-minute 3`, fresh session): the wire log
shows the token bucket doing exactly what it says — a small initial
burst, then request starts paced at **exactly 20.0s** (60 ÷ 3) apart,
while the agent kept working normally and closed with a correct
file:line-cited summary of its own rate limiter.

15. **Retro-audit across all runs** (wire logs): round 1 peaked at 8
    req/min, round 2 at 6, round 3 at 4 — never near 40, but that was
    luck of slow turns, not a mechanism. `--requests-per-minute` is the
    mechanism and it works; it just isn't on by default. **Would make:**
    provider descriptors carrying a default RPM hint (NIM = 40) so tina
    throttles to the account's real ceiling without the user reading
    vendor docs first.
