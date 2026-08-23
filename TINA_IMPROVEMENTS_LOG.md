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
   **→ REMOVED 2026-08-21 (owner decision):** the flag shipped briefly and
   was taken back out — a key on a command line leaks via shell history,
   process listings, and audit logs; credentials belong in
   `~/.tina/config` (chmod 600) or the environment. Passing `--api-key`
   now fails fast (`Could not find an option named "--api-key"`), the
   dead `Config.apiKeyOverride` field went with it, and resolution is the
   clean file > env chain through `registry.authFor`. The pool edge
   dissolved with the flag.

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
    **→ Implemented 2026-08-21 (improvements run, Run F):** second trigger
    in the mid-turn gate — spendTriggered = perTurnLimit set AND turnTotal
    ≥ perTurnLimit/2 AND estimate > threshold/2 (floor), ORed with the
    size trigger, both sharing the attempt gate and the splittability
    pre-check; threshold 0 still disables everything; spend-only fires
    emit a `[compact] turn spend X/Y crossed 50%` notice so headless
    drivers can see which trigger acted. Run F (tina, session
    20260820-202356-3bd9) wrote the implementation and the main
    spend-fires test across two max-steps-terminated legs; three sibling
    tests it left mis-scripted (completions with no TokenUsage, so spend
    never actually crossed) were repaired by hand per the #22 rule.
    Engine 729 / root 667 green. Postscript: this run also exhausted 60
    then 40 steps legitimately on a two-file task — the driver now
    launches with `--max-steps 500`, and the product default was raised
    to match (50 → 500, with kMaxToolCallsPerRun 500 → 5000 to keep the
    designed ~10× tool-call headroom).
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
    makes an innocent query look like a failure.
    **→ Implemented 2026-08-21 (improvements run, Runs G2+G3):** the
    enumerator layer returns the file itself for a file root (c4618b3),
    and both consumers honor it end-to-end (5b2ca42): glob accepts a
    file root and matches the pattern against its basename; grep's Dart
    fallback reads the root itself instead of the phantom
    `<file>/<basename>` join. The rg subprocess path was never broken.
17. **Default maxSteps (50) is tight for small-model writes.** The first
    Run A attempt spent all 50 steps exploring (plus 12 wasted on denied
    `cat`/`head`/`grep` bash shapes) and hit the max-steps ceiling with
    zero writes — then exited 0 (see #5, since fixed). The resume with
    `--max-steps 80` + the denied shapes allowed landed the change in 37
    steps. Driving pattern for small models: let them explore once, then
    resume with a directive; or raise the ceiling up front on any run
    expected to write code.
    **→ Implemented 2026-08-20:** the default maxSteps is 500 now (raised
    after Run F burned the then-80 ceiling legitimately; driver launches
    use ≥500 and the driving rule is formalized as "minimum 500").
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
    **→ Implemented 2026-08-21 (improvements run, Run L):** `--model`
    normalizes into Config.provider/Config.model at parse time, so every
    downstream consumer (buildStartupProvider, the workflow runner's
    defaultModelReference, the SessionRecorder's providerId) inherits it
    with no other file touched. A value containing '/' is a full
    `<provider>/<model>` ref split on the FIRST slash (the
    session_restore convention — model ids may themselves contain slashes,
    e.g. `openrouter/stealth/ox-alpha`); a bare value overrides only the
    model. Precedence: flag > `[default]` file > env/descriptor default.
    Verified live: `--model openrouter/stealth/ox-alpha` against a
    pool-default config sent its request to https://openrouter.ai on the
    wire (not the pool's members); `--model nosuch/x` fails fast with the
    unknown-provider FormatException. Scope note: a headless `--resume`
    without `--model` still uses the config default (the persisted
    conversation model is honored on the TUI path only, per #4's fix) —
    `--model` is the explicit way to pin it headlessly.
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
    a resume can tell the model WHICH step broke it.
    **→ (a) Implemented 2026-08-21 (improvements run, Run H):** the agent
    takes an optional ToolResultVerifier; after a successful edit/write it
    appends the verdict to the tool result the model reads next step.
    Headless wires DartAnalyzeVerifier (`dart analyze <file>`, 30s-bounded,
    capped error block; null on clean/timeout/failure). (b) recorder
    stamping remains open.
    **→ (b) Implemented 2026-08-21 (improvements run, Run N), REFRAMED:**
    per-step recorder stamping turned out to be subsumed — #22a's verdicts
    ride the tool-result messages and #25 persists those write-through, so
    a resumed transcript already carries them. The real gap was CURRENT
    tree state: compaction can drop old verdicts, and the break may
    pre-date the session or come from outside (a kill, a manual edit). So
    instead: a startup tree-health check — `projectCheck()` on
    DartAnalyzeVerifier (whole-project `dart analyze`, 30s-bounded,
    shares the #22a parse/cap core) runs before the headless turn when a
    pubspec.yaml is present, and a `<tree-health>` block naming the errors
    is prepended to the user input so the model fixes FIRST. Verified
    live: a broken scratch package's persisted transcript carries the
    block with the exact diagnostic; a clean package gets no notice.
    Cost note: every headless run in a Dart project now pays one bounded
    project analyze (~seconds on small projects, ~15s on this monorepo)
    before the first request.

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
    **→ (a)+(b) Implemented 2026-08-21 (improvements run, Run I):** each
    timeout raise site names its flag and the observed seconds, and
    humanizeException passes the message through; a wall-clock timeout
    awaiting headers is now terminal for the transport retry loop (no
    more re-sending an unchanged payload into the same wall — the error
    stays transient so the pool fails over with real spacing). (c) the
    size-scaled default remains open.
    **→ (c) Implemented 2026-08-21 (improvements run, Run M):**
    `scaledRequestTimeout(bodyBytes)` — 30s + 1s per 4096 bytes, capped
    900s (220KB → 85s, ~4.7x the observed 18s) — applied at each
    provider's send site when the configured value EQUALS the built-in
    default (nobody passes a flag to request the default; any other
    explicit value is a deliberate choice and wins verbatim). No Config,
    registry, or constructor signatures changed; the existing named
    errors automatically report the scaled seconds.

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
    **→ (a) Implemented 2026-08-21 (improvements run, Run I):** the
    stream-idle raise names its flag and the observed seconds ("no
    stream events for 60s — raise with --stream-idle-timeout"), and the
    idle clock now measures raw bytes (resp.stream.timeout before SSE
    parsing) so a silent prefill names the right knob. (b) the
    size-scaled idle default remains open.
    **→ (b) Implemented 2026-08-21 (improvements run, Run M):**
    `scaledStreamIdleTimeout(bodyBytes)` — 60s + 1s per 3072 bytes,
    capped 900s (244KB → 141s, ~1.7x the measured 81s silent prefill) —
    same "== default scales, explicit wins" contract as #23(c), applied
    identically across anthropic/gemini/openai_compatible. A plain launch
    now survives a large resume without hand-passing either flag.

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
    **→ Implemented 2026-08-21 (improvements run, Runs J+J2, driver
    repairs):** the agent fires awaited observer seams — onHistoryAppend
    after every history add, onHistoryReplace once after compact's
    rewrite — and headless persists through the SessionRecorder as each
    message is produced (turn-end flush deleted). Null observers suspend
    zero times: the notify helpers return null rather than a completed
    future, because an async no-op await still yields a microtask —
    enough to hang two gate-based scheduler tests. Live-verified: a real
    headless run's project-local transcript holds all messages before
    process exit. The TUI's SessionController still flushes at turn end
    (same seam available when wanted).

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
    **→ Implemented 2026-08-21 (improvements run, Run K + driver repairs):**
    `HeadlessWatchdog` (lib/host/headless_watchdog.dart)
    resets its idle clock on every agent event-bus emission; on expiry it
    fires once — a `[watchdog]` diagnostic block on stderr (last event,
    its age, total events, plus the honest note that Dart cannot retrieve
    the parked await's stack), then tears the turn down via
    `agent.run`'s `cancelSignal`, with a 5s grace before a hard exit(2)
    (the budget guard's clean-exit pattern). Flag `--watchdog-seconds`
    (default 300; 0 disables; headless only). One honest deviation from
    the original want: no stack dump of the parked await — Dart has no
    API to fetch another await's stack, so the diagnostic says so instead
    of printing a misleading one.

27. **A permission-denied headless run dithers in a denial spiral — and the
    new tree-health notice amplifies it (would make).** Observed live while
    verifying #22(b): a no-`--allow` probe run in a broken scratch package
    received the `<tree-health>` block, correctly diagnosed the error,
    tried to fix it — `edit denied`, `write denied`, then NINE more
    denied bash shapes ending in a denied `bash: dart analyze` — and never
    answered the actual prompt (the driver's 240s kill ended it; a sibling
    run whose model simply replied exited 0). Run A already logged 12
    steps wasted on denied shapes; the root cause is unchanged: headless
    refuses every ask, but nothing tells the MODEL that asks are futile,
    and nothing circuit-breaks repeated denials of the same tool.
    **Would make:** (a) the headless denial message should state plainly
    "asks are auto-refused headless; rephrasing will not help — proceed
    without this tool or answer from what you have"; (b) the agent loop
    should count consecutive denials per tool and inject a notice (or
    stop) after N; (c) the tree-health notice should be conditioned on
    the policy actually permitting edit/write, or phrased "fix these
    first if you are permitted to edit". Driving remedy meanwhile:
    always launch with the intended `--allow` shapes.

28. **The pool "rotates over" warning prints even when the pool is not used
    (cosmetic, but misleading — would make).** Observed live while
    verifying #18: a run launched with `--model openrouter/stealth/ox-alpha`
    against a pool-default config still prints `tina: pool "pool" rotates
    over: ...` on stderr, because the warning fires at registry-attach
    time from the config-file declaration, not at resolve/use time. It
    reads as "the pool is active" when the run uses a single direct
    provider — bad enough that Run L's summary mistook the warning's
    member list for proof the flag had taken effect (the wire log was
    needed to settle it). **Would make:** emit the warning when a pool
    descriptor is actually RESOLVED for a build, or stamp it with "when
    used". Trivial severity; pure operator-confusion cost.

29. **Headless `--resume` ran the conversation under the config default,
    not the model it was actually using (owner-directed fix).** The
    `/model`-persistence work (4ff1ff8) rebuilt the active conversation
    from its stored model ref in the TUI only — the headless path built
    its startup provider purely from `Config.provider`/`Config.model`, so
    `tina --resume <id>` silently switched the conversation back to the
    config default (with a pool default: to whatever member rotated
    first). Owner contract (2026-08-21): **`--model` flag > persisted
    active-conversation model (on `--resume`/`--continue`) > `[default]`
    file > env/descriptor default.**
    **→ Implemented 2026-08-21 (owner-directed, Run O + driver repair):**
    `Config.modelExplicit` carries flag-explicitness past #18's
    parse-time normalization (the flag folds into provider/model, so
    explicitness must travel separately or the precedence is
    unimplementable). `buildStartupProvider()` consults the active
    conversation's meta ref when no flag was passed: first-slash provider
    (the session_restore convention), a single stderr warning + config
    fallback when the ref is no longer resolvable — a resume never
    hard-fails on a stale ref — and apiKey/baseUrl overrides applied only
    when the ref's provider matches config's (the TUI guard pattern).
    Run O's code and unit tests were correct, but the live proof FAILED
    initially: the headless `SessionRecorder` created its conversation
    meta with `model: null` (only the TUI creation path and `/model`
    swaps ever stamped one), so the meta the new code read was always
    null and every resume still fell back to the pool. tina had skipped
    the live checks its prompt required — exactly where this would have
    surfaced. Driver repair: `bin/tina.dart` now stamps
    `ConversationMetaInput.primary` at recorder construction, mirroring
    the TUI's initialRecorder (write-once for fresh sessions; a resume
    attaches, so persisted swaps are never clobbered). Wire proof, three
    live runs: fresh `--model openrouter/stealth/ox-alpha` →
    https://openrouter.ai with the meta stamped
    `openrouter/stealth/ox-alpha`; resume with NO flag →
    https://openrouter.ai (the persisted meta wins; this was
    integrate.api.nvidia.com before the repair); resume WITH `--model
    nim/thinkingmachines/inkling` → https://integrate.api.nvidia.com
    (the flag wins). Engine 763 / root 698 (690 + 8 new) green.

30. **TUI: the permission prompt sometimes renders overlapping the tail of
    the last tool output (owner-observed).** When a permission request
    draws right after streamed tool output (or a still-live spinner/
    inline region), the prompt's first line can glue itself onto or over
    the output's last line instead of starting on a fresh one — the
    approval line (`tool: key`) becomes hard to read and looks like part
    of the result. The draw path (TuiConversationHost.askPermission →
    chat.yellow) does not guarantee the previous output ended with a
    newline, nor that the spinner/region has quiesced before the prompt
    renders. **Would make:** before drawing a permission prompt, force a
    line break (and settle any active spinner/region) so the prompt
    always starts at column 0 of a fresh line — the same discipline the
    tool-start/tool-complete notices already follow.
    **→ Implemented 2026-08-21 (improvements run, Run P + driver touch-up):**
    all three legs. (a) `PermissionResponse.note` — a model-facing
    explanation an auto-refusing asker supplies (HeadlessHost, the
    background-conversation TUI branch, and the workflow asker all set
    it): "Non-interactive run: permission asks are auto-refused —
    rephrasing will not change this." It rides on the denied tool result;
    the stderr hint stays for the operator. A static deny RULE gets no
    note (the asker was never consulted; the allowed-shapes text is the
    remedy there). (b) A per-tool consecutive-denial circuit breaker in
    the agent loop: at ≥3 denials of the same tool (an allowed call of
    that tool resets the streak) the denial result itself says "stop
    calling it" and a warning notice marks the trip for the operator.
    (c) The `<tree-health>` block now goes through
    `DartAnalyzeVerifier.wrapTreeHealth`: when `editActionable(policy)`
    (a scratch-file `edit` probe against the run's policy) says the run
    cannot edit, the block gains "You do NOT have edit permission in
    this run — do not try to fix these." Live acceptance (the exact
    probe that exposed the spiral): a no-`--allow` run in a broken
    scratch package answered the prompt with ZERO denials — the model
    read the file, cited "the no-edit constraint", and exited 0 (the
    pre-fix behavior was 11 denials and a driver kill). Driver
    touch-up: removed a redundant second streak-reset (the allow-time
    reset already covers it) and dart-format. Engine 767 / root 702
    (driver-run counts; Run P's summary claimed "534 across the repo" —
    a subset miscount, its fourth in a row). An unplanned bonus proof:
    Run P's first launch lost its `--allow` flags to a launcher typo,
    and tina — reading only its own denial results — stopped after 3
    denials and reported honestly instead of spiraling: the fix's
    target behavior, exercised by accident.
    **→ Implemented 2026-08-21 (improvements run, Run Q):**
    `ScrollingTextRegion.ensureNewline()` (tina_console) — terminate the
    current partial row (a no-op on empty/newline-terminated rows) — called
    as the first draw of the permission prompt in BOTH askPermission
    branches (TuiConversationHost) and the workflow asker's two prompt
    lines. The ask fires in the agent loop BEFORE any tool-start notice,
    so the prompt is the first structured line after unterminated streamed
    prose — exactly where it glued onto the output tail. Console 784
    (781 + 3 new ensureNewline tests) / root 702 / engine 767, all
    driver-verified. Run Q's summary again contained one false claim:
    "root analyze 33 → 0 (env-wide analyzer fix outside repo)" — root
    analyze is unchanged at 33 (verified; no analyzer config exists
    inside or outside the repo, nothing touched). Fifth count/claim
    misreport across the runs; the code itself was correct.

31. **`ChatAgentSink.notice` shares the #30 glue hazard (would make).**
    Found read-only while fixing #30 (deliberately not fixed in the same
    run): `notice()` routes its message straight through
    `chat.dim/yellow/red` with no row termination, so a notice drawn
    while the current row holds unterminated streamed prose (a
    mid-stream warning, the `[cancelled]` notice) glues onto it just
    like the permission prompts did. Most notices follow
    newline-terminated tool lines, so it is rarer — same class, lower
    frequency. **Would make:** route notice() through
    `ensureNewline()` too (one line), or have the callers own it.
    **→ Implemented 2026-08-21 (improvements run, Run R):** the notice
    moved into the pool descriptor's builder with a warn-once flag — it
    fires on the pool's FIRST BUILD, never at attach. [warn] injects the
    sink so tests assert the timing (3 new: attach warns nothing; first
    build warns once with the member list; a second build stays at one).
    Live proof both directions (driver-run): `--model nim/…` against a
    pool-default config prints ZERO pool warnings (previously the member
    list printed at attach — the noise that fooled Run L's
    self-verification); a pool-default run prints it exactly once, on
    first use. Root 705 (702 + 3). Verified 2026-08-23 after an
    environment rebuild wiped ~/.tina/config (recreated from the owner's
    standing key directive) and stale pub resolutions: root 33 / engine
    2 / console 3 analyze all back at pre-existing baselines.

32. **`process_tree_test` reports a healthy kill as a failure in the
    rebuilt environment — zombie liveness (would make).** After the
    2026-08-23 sandbox rebuild, `kills a backgrounded descendant that
    survives a bare kill of the root` fails deterministically while the
    manual equivalent works: `killProcessTree` DOES kill the descendants
    (SIGKILL lands), but this container's PID 1 never reaps orphans, so
    the killed children persist as zombies — and the test's liveness
    check (`kill -0 pid`) counts a zombie as alive. The product behavior
    is correct; the test's definition of "dead" is wrong in any
    PID-1-doesn't-reap container. **Would make:** treat state `Z` in
    `/proc/<pid>/stat` as dead in the test's `_alive` (and consider the
    same in `killProcessTree`'s grace loop, where a lingering zombie
    currently eats the full grace delay before a pointless SIGKILL).
    Engine suite stands at 767 tests: 766 green + this 1
    environment-caused failure (bash_tool's cap test remains the known
    order-dependent flake; passes in isolation).
