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
   **→ Implemented 2026-08-20 (improvements run, Run B):** `--models
   <provider>` prints the resolved catalog (live models.dev + the
   provider's own /v1/models awaited, so it matches the TUI picker),
   bare `--models` lists known provider ids, unknown ids exit 1 naming
   the known set. Verified live (`--models hetzner` prints the catalog
   incl. models absent from the static descriptor).
2. **Permission-classifier friction was environmental, not tina's fault** —
   but it did surface that every credential path (env var, `~/.tina/config`)
   is all-or-nothing: no `--api-key` flag for a one-shot run without touching
   config state. A `--api-key` flag (or `TINA_API_KEY`) would make ephemeral
   drives like this one cleaner.
   **→ Implemented 2026-08-20 (improvements run, Run B):** `--api-key` wins
   over both the config file and env (flag > file > env) at the single
   auth-resolution seam in `Config.parse`; read once, lands on
   `Config.apiKey`, never persisted. Verified live: a bogus flag key draws
   a provider 401 while the config file holds the real one. One edge left
   open: under a pool `[default]` the flag is a no-op — pool members take
   their keys from member config, and one string can't be right for a
   multi-provider pool anyway.

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
   **→ Implemented 2026-08-20 (improvements run, Run A):** `_runNonInteractive`
   exits 2 whenever the turn ends with `agent.abortedReason` set (budget,
   provider, max-steps). Demonstrated live twice while driving: the
   max-steps abort of Run A's first attempt exited 0.
6. **grep tool scans binary/asset dirs** (`examples/workspace/assets/*.png`
   warnings) — noisy in stderr; a default ignore for binaries (or
   `.gitignore`-aware skipping) would clean long greps. (Cosmetic.)
   **→ Implemented 2026-08-20 (improvements run, Run D):** the pure-Dart
   fallback sniffs the first 8KB for a NUL byte and skips binaries
   silently with a one-line `... (skipped N binary files)` summary;
   genuine I/O and strict-decode failures keep the warn-and-skip. The
   ripgrep path needed nothing. (Run D also hit the deadlock logged as
   #26 mid-turn and was re-driven to completion.)
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
    **→ Implemented 2026-08-20 (improvements run, Run C):** the deny
    `ToolResultBlock` now lists the ALLOW patterns that exist for the tool
    this session (`PermissionPolicy.allowedPatterns`) and, for bash, the
    always-allowed native tools, closing with an explicit
    do-not-retry-unchanged. Verified by the new engine tests (deny content
    names the patterns, says `none` when empty, points bash at the native
    tools); the next live dogfood (a run hitting a denied shape) will show
    it in a wire log.
11. **Small-model steering: prompt nudge exists and is ignored.** Correction
    from round 3's wire log: the system prompt ALREADY says "Prefer the
    dedicated read-only tools (ls, stat, which, glob, grep, search, git)
    over bash for inspection and lookup" — muse-glimmer flouted it anyway.
    Prose steering doesn't reach small models; the remedy that would is #10
    (put the exact `--allow` rule and native-tool suggestion in the deny
    tool-result itself, where the model must read it to continue).
    **→ Implemented with #10, 2026-08-20 (Run C).**

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
    **→ Implemented 2026-08-20 (improvements run, Run A):**
    `HeadlessHost.kHeadlessSummaryInstruction` is appended to every
    non-interactive `--prompt` turn in `bin/tina.dart`.

## Improvements run (post-merge) — driving tina through the backlog

Reopened after PR #15 merged. Same discipline: tina implements, I verify
and commit. Two new observations from the first run of this round:

16. **glob on a file path warns instead of matching quietly.** A glob
    whose root is a file (`glob pattern=* path=bin/tina.dart`) logs
    `FileSystemException: Not a directory, errno 20` + "failed to list,
    skipping subtree" to stderr. A file root should either match the
    pattern against the file or return no matches — the exception noise
    makes an innocent query look like a failure. (Would make; not yet
    scheduled.)
17. **Default maxSteps (50) is tight for small-model writes.** The first
    Run A attempt spent all 50 steps exploring (plus 12 wasted on denied
    `cat`/`head`/`grep` bash shapes) and hit the max-steps ceiling with
    zero writes — then exited 0 (see #5, since fixed). The resume with
    `--max-steps 80` + the denied shapes allowed landed the change in 37
    steps. Driving pattern for small models: let them explore once, then
    resume with a directive; or raise the ceiling up front on any run
    expected to write code.
18. **No headless `--model` override (would make).** Model alternation
    exists per-conversation (TUI `/model`, persisted across resume),
    per-task (sub-agent `modelReference`), and for the permission
    classifier — but a headless run can only take `~/.tina/config`'s
    `[default]`, and `--resume` honors the conversation's persisted model,
    so there is no way to run (or resume) a headless session under a
    different model without editing config state. A `--model
    <provider/model>` flag beating both the config default and the
    persisted label would enable alternating models across headless
    rounds — cheap explorer for reads, strong model for writes.
19. **No way to spread load across providers → Implemented.**
    A session pinned to one provider inherits that provider's rate
    ceiling (NIM: 40 RPM) with no recourse; throughput above it is
    impossible even when equivalent models live on several providers.
    Landed as `PooledProvider` (`packages/tina_engine/lib/src/llm/
    pooled_provider.dart`): round-robin over N resolved members, before-
    content failover to the next member within the same send (after-
    content errors surface — failover would duplicate partial output),
    per-member cooldown, last-error surfacing when everyone fails, and a
    cooling error rather than hammering when all members are down. Config
    declares a pool as `[providers.<id>] members = ["a", "b"]` (nested
    pools, unknown members, and self-reference are warned about and
    skipped at startup); the pool's catalog is the union of its members'
    and `<pool>/<model>` rotates across them. Per-member spacing falls
    out of the existing limiter for free — the queue key is
    endpoint+API-key, so each member is spaced against ITSELF (three
    members at 1500 ms ≈ 120 RPM aggregate). The session-wide
    `--requests-per-minute` stays the outer ceiling — set it to the sum
    (or 0), else it bottlenecks the pool at one member's cap. Member
    entries are bare provider ids (every member serves the `<pool>/<model>`
    id) or FULL references (`"nim/meta/muse-glimmer-30b"`,
    `"hetzner/Qwen3.8-27B"` — the member is pinned, so one pool can mix
    models and providers; a `/model` swap on a mixed pool is undefined and
    should be avoided). Verified live 2026-08-20: a two-member pool
    (NIM muse-glimmer + Hetzner Qwen3.8-27B, `min_request_interval_ms =
    1500`) served a 4-request headless run in strict alternation — NIM,
    Hetzner, NIM, Hetzner — correct model per member, zero errors. One
    residual gap: a pinned model missing from the provider's compiled
    catalog (muse-glimmer vs NIM's static list) serves fine but isn't
    listed in the pool's catalog until the live/models.dev catalog loads.
    Per-provider limit overrides (`[providers.<id>] requests_per_minute`)
    NOT included — deferred until #15 (descriptor RPM hints) lands, which
    is the better home for per-member defaults.
20. **BUG (misdiagnosed — NOT a bug, withdrawn).** A hard-killed headless
    run looked like it persisted nothing: `~/.tina/sessions/<id>/` held
    only a `session.json` stub with no events. Wrong tree — the store is
    SPLIT: the manifest lives globally under `~/.tina/sessions/`, the
    conversation events live repo-locally under
    `<cwd>/.tina/sessions/<id>/<conversationId>.jsonl` (see
    `JsonlSessionStore`'s header comment). The killed Run B's events were
    on disk the whole time and `--resume` would have worked; I killed and
    relaunched fresh unnecessarily. Lesson: check both roots before
    declaring session loss. (The split itself is undiscoverable — the
    `session:` stderr line prints only the global id with no hint of
    where events land; a `--sessions` listing that names the event files'
    location would prevent the next misdiagnosis.)
21. **BUG (fixed): an empty model completion ended a headless run as a
    silent SUCCESS.** Poolside/laguna-xs-2.1 on NIM, under worker
    exhaustion (`503 ResourceExhausted` on later probes), answered a
    mid-task request with `200` + zero content blocks. The agent loop
    treated an assistant message with no text and no tool calls as a
    normal end-of-turn: the run exited 0 after 5 of 120 steps, no
    summary, nothing wrong visible anywhere. Worse than a crash — it
    looks like success. Fixed in two layers: `PooledProvider` treats an
    empty completion as a failed member response — cooldown + failover to
    the next member within the SAME send (the agent-level retry re-rolls
    the dice on the same flapping member; the pool picks a different one)
    — and `Agent.run` no longer records or accepts a no-block completion:
    it retries the send once and aborts with `model returned an empty
    completion` if it repeats. The empty message is never appended to
    history (some providers reject an empty assistant message on the next
    request).
22. **A compile-broken tree cannot heal itself via resume.** Run B's
    provider-killed attempts left `lib/config.dart` with new fields that
    no constructor initialized (exit 254 at `dart run` compile time,
    before any prompt is sent). Resume is useless there — the agent never
    gets a turn — so the driver must repair the tree by hand. Two
    mitigations worth building: (a) a fast post-edit compile gate in
    headless runs (analyze the edited file after each edit step, feed the
    error straight back to the model while its own edit is still in
    context — cheaper than discovering a pile of them at test time); (b)
    the session recorder stamping the tree's compile status per step, so
    a resume can tell the model WHICH step broke it. Neither built yet.

23. **A 30s default request-timeout silently kills large-context resumes.**
    Run B's resumed session carries ~220KB of conversation (each resume
    appends). Hetzner serves that payload fine — ~18s prefill, measured
    out-of-band with a same-size curl — but `--request-timeout` defaults to
    30s, so the send died as `error: Request timed out`, and the retry
    policy re-sent the SAME oversized request into the SAME wall four
    times (1 + 3 retries) before aborting with exit 2. Nothing in the
    output names the `--request-timeout` knob, so the failure reads like a
    dead provider rather than a too-small cap. **Would make:** (a) the
    timeout error should name the flag and the elapsed-vs-cap numbers
    (`request exceeded 30s — raise with --request-timeout`); (b) a retry
    after a wall-clock timeout on an unchanged payload is doomed — back
    off exponentially at minimum; (c) worth considering a default scaled
    to request size (the estimate the limiter already computes). Driving
    remedy meanwhile: launch with `--request-timeout 180`.

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
    **→ Implemented 2026-08-20 (improvements run, Run E):**
    `ProviderDescriptor.requestsPerMinute` — NIM's descriptor ships the
    observed 40/min ceiling, and the registry installs it as per-queue-key
    spacing (60 s ÷ rpm) when the provider builds, so the hint holds even
    with the registry-wide limiter disabled. User override: `[providers
    .<id>] requests_per_minute` beats the hint, `0` disables spacing for
    that provider's queues. Precedence: override > hint > `[limits]
    min_request_interval_ms`. Two latent gaps the new tests caught: the
    wrap decision and the send fast-path both read the GLOBAL interval,
    so a hint went unenforced whenever the global limiter was off — both
    now read the effective per-key interval. Engine 725 / root 667
    green; live smoke: `--models hetzner` boots the pool with the wiring
    in place. (Run E ended `error: member returned an empty completion`
    mid-test-writing — NIM flapping again, #21 — leaving a compile scar
    in the new test group; repaired by hand per the #22 rule: a
    compile-broken tree can't heal itself via resume.)

24. **Stream-idle-timeout (60s default) kills healthy prefills on large
    contexts — and the error names the wrong knob.** Measured on Hetzner
    Qwen3.8-27B: a 244KB request WITH tool schemas sits completely silent
    for **81 seconds** before its first generation chunk (110KB without
    tools: 16s; the provider is computing prefill, not dead). tina's
    `--stream-idle-timeout` defaults to 60s, so the send dies as
    `error: Request timed out` — the SAME string the request-timeout uses —
    and the retry policy walks an exponential backoff into the same wall
    (observed gaps of 306s/130s between wire-log POSTs while every retry
    was doomed). Two compounding traps: (a) one error string for two
    different knobs, so the operator raises `--request-timeout` (as I did,
    30 → 180 → 600) and nothing changes; (b) the idle clock measures from
    the last received byte, which on a silent prefill punishes exactly the
    requests that are working hardest. **Would make:** distinct error
    strings that name their flag and the observed gap (`no bytes for 60s —
    raise --stream-idle-timeout`), and a default idle budget that scales
    with the request-size estimate the limiter already computes. Driving
    remedy meanwhile: `--stream-idle-timeout 300` (plus
    `--auto-compact-threshold 40000` to shrink the requests themselves —
    244KB contexts ride forever under the 120K default because the
    estimate (~61K) never crosses it, yet each re-send pays the full
    prefill).

25. **A mid-turn kill persists the tree but not the conversation.** Killing
    a headless run mid-turn (as a driver must, when a run dithers or rides
    a timeout wall) leaves every file edit on disk but loses the turn's
    conversation events — the recorder flushes at turn end, so 13 tool
    calls' worth of reasoning vanished (no session dir was ever created
    for the fresh run; a resumed run's events file sat at its pre-turn
    mtime). `--resume` is useless there — the session either doesn't exist
    or predates the turn — and the model must restart from a directive,
    re-reading what it already read. **Would make:** event write-through
    (or a periodic flush) so a killed run resumes where it stopped — the
    original session-persistence design (#7) quietly assumes graceful turn
    ends. Workaround meanwhile: fresh session + directive that names
    what's already on disk; edits survive, so this recovers cheaply.

26. **A headless run can deadlock silently — no error, no exit, no watchdog.**
    Run D wedged mid-turn: an edit completed, the model streamed a sentence
    of intent ("Let me update:"), and then nothing — forever. The process
    sat in `futex_do_wait` with zero CPU over a 10s sample and two idle
    sockets, 25+ minutes after its last wire request; no timeout fired
    because no request was in flight (the hang is below/outside the
    provider stack — plausibly the edit mutation lock or another internal
    await that never resolves). A driver sees a hung run with no
    diagnostic and must notice the silence themselves. **Would make:** a
    turn-level liveness watchdog in headless mode (no agent-sink event for
    N minutes → abort with a stack dump of where the loop is parked), the
    same way the budget guard already converts runaway spend into a clean
    exit-2. Driving remedy meanwhile: watch the wire log's mtime and kill
    by hand.
