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
    **→ The glue itself fixed 2026-08-23 (improvements run, Run U —
    tina session 20260823-113436-ac51):** `notice()` now calls
    `chat.ensureNewline()` after its `_flushMarkdown()`, the same idiom
    the #30 permission prompts adopted — one line in
    `lib/chat_agent_sink.dart`. Regression test pins the hazard shape:
    streamed output left mid-row (no trailing newline, notice before
    `toolComplete`) must NOT concatenate (`partial row[watchdog]…`
    asserted absent; the notice asserted alone on its own row).

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
    **→ Implemented 2026-08-23 (improvements run, Run U — tina session
    20260823-113436-ac51):** both sites. The test's `_alive` consults
    `/proc/<pid>/stat` first on Linux and counts state `Z` as dead
    (state parsed after the LAST `)` — comm can contain spaces and
    parens; macOS keeps bare `kill -0`). `killProcessTree`'s grace wait
    is now a 25 ms poll that ends as soon as every pid is dead-or-zombie
    and SIGKILLs only the genuinely alive, via a shared `_isDeadAsync`
    (Linux: /proc state `Z`, an unreadable entry falls through to
    `kill -0`; elsewhere: `kill -0` alone). Verified in this
    PID-1-never-reaps container: the descendant-kill test went from
    deterministic red to 3× consecutive green, and a timed probe of a
    two-sleeper tree with 2 s grace returned in 234 ms (was a hard
    ≥2000 ms). Engine 767 green, root 758 green, analyze baselines
    unchanged.

33. **notcurses: a mute terminal leaves the keyboard dead after the
    reply-guard detour (would make).** CONFIRMED LIVE 2026-08-23 with
    `tool/mute_pty_driver.py` (a mute-terminal variant of
    altkey_pty_driver.py): when the terminal answers none of init's
    queries — a tmux window created with `new-window -d`, or any
    headless-launch-then-attach flow — `TerminalReplyGuard` arms its
    fd-0 detour, feeds notcurses the fallback DA1, init completes, the
    welcome screen renders… and not one keystroke ever arrives for the
    rest of the session. Root cause: notcurses' input thread captured
    ITS tty fd during init — while fd 0 was the detour pty slave — and
    `guard.restore()` then closes the master, killing that pty. The
    vendored pump (`dart_notcurses/native/src/input_pump.c`) polls
    `notcurses_inputready_fd()`, which that dead reader never signals
    again. The answering-terminal path is unaffected (driver PASS),
    which is why only the detour case dies. **Would make:** when the
    detour is armed, keep the master open for the session and bridge
    real stdin into it — after `restoreStdin()` puts the real stdin back
    on fd 0 (nonblocking, as notcurses expects), a small poll/read/
    write loop (the FFI plumbing already exists in
    `PosixReplyGuardOs`) copies bytes from fd 0 to the master, so
    notcurses keeps decoding from a live pty. The backend must own the
    guard for the session and shut the bridge down on `stop()`.
    Acceptance: `tool/mute_pty_driver.py` flips from DEAD-KEYBOARD to
    PASS with no probe changes, teardown stays clean (<10s exit), and
    `tool/altkey_pty_driver.py` still passes.

    **FIXED 2026-08-23** (same day as the live confirmation). The master
    is no longer closed on restore: [restoreStdin] keeps it and hands it
    to a new [StdinBridge] — a 10 ms `Timer.periodic` pump copying
    fd 0 → master (4096-byte chunks, ≤16 per tick so a paste cannot
    starve the event loop, 256 KiB drop-oldest bound if notcurses stops
    reading). `TerminalReplyGuard.restore()` starts the bridge only when
    a master exists; the new idempotent `shutdown()` stops it, and
    `NotcursesBackend.stop()` calls that before `_nc.stop()` so the pump
    thread never reads from a pty mid-close. Read/write errors are
    swallowed with a single debug-mode trace; every tick is best-effort.
    Tests: `test/init_reply_guard_test.dart` grew a `_BridgeFakeOs`
    (scripted stdin queue + write budget/EAGAIN/throw) covering copy,
    short-write retry, buffering, overflow, caps, error recovery,
    released-master no-op, lifecycle, plus three guard-level bridge
    tests — 25 passing.

    **REDESIGNED 2026-08-23 (later the same day): the swap-back design was
    itself the bug.** The fix above still lost every keystroke under the
    diag harness. Evidence ladder (kept in `tool/syscall_diag_driver.py`):
    `/proc/<pid>/fd` readlinks showed notcurses' input thread held NO fd
    to the detour slave after init — it had opened the real tty by name
    (from `ttyname(stdout)`) as its own private fd; `/proc/<pid>/task/*/
    /syscall` + reading the pollfd array out of `/proc/<pid>/mem` showed
    that thread parked in `ppoll(fd 0)` — polling fd 0, reading fd 13.
    Linux binds the file description a poll waits on AT SYSCALL ENTRY:
    the thread entered ppoll during init, when fd 0 was the detour
    slave, so its poll waits on the detour pty forever no matter what
    the fd table says later. Putting the real stdin back on fd 0 makes
    poll and read disagree — the thread READS the real tty while its
    POLL waits on a pty nobody feeds. (The first bridge made it worse:
    draining fd 0 — the read side — to feed the master — the poll side
    — starved the reader it was trying to serve.) **The fix that holds:
    never swap fd 0 back.** The detour pty stays notcurses' terminal for
    the whole session; `finishInit()` (renamed from `restore()`) calls
    `beginBridgedSession()` — snapshot termios, cfmakeraw the SAVED
    real-stdin fd (not fd 0), set it O_NONBLOCK, copy winsize, forward
    SIGWINCH — and `StdinBridge.tick()` reads that saved fd into the
    detour master, so poll side and read side are one pty again.
    `shutdown()` reverses it: termios back, fds closed, master released.

    **And a second bug hiding behind the first: the default constructor
    built TWO `PosixReplyGuardOs` instances** (`_os = os ?? posix(),
    _bridge = StdinBridge(os ?? posix())`), so with
    `TerminalReplyGuard()` — exactly what `NotcursesBackend` uses — the
    bridge ticked an os layer whose master/source were forever −1 and
    silently copied nothing. Every unit test injected one shared os, so
    the suite stayed green while production moved zero bytes; only the
    pty-driver acceptance runs caught it (`tool/mute_pty_driver.py`
    stayed DEAD-KEYBOARD with FIONREAD on the real slave stuck at 1
    forever). Now a redirecting constructor guarantees one instance,
    with a `sharesOsLayer` regression test.

    Final acceptance, all three drivers green: `tool/mute_pty_driver.py`
    PASS (`pump: 'b' id=0x62`, `'q'` quits, rc=0 — and the driver now
    drains the master for the whole run; its old stop-at-render read
    loop hid every post-render stderr line), `tool/altkey_pty_driver.py`
    PASS (Alt+b → `id=0x62 mods=2 ALT`), `tool/stop_hang_driver.py`
    STOP-CLEAN (exit 0.1s after quit). Console suite 811 green.

## Improvements run, round 2 — fresh backlog (2026-08-23)

Items #1–#33 are all implemented, withdrawn, or verified; PR #19 carries
the last batch (#33, #31, #32 — the latter two implemented by tina
itself in Run U, session 20260823-113436-ac51, engine 767 / root 758 /
console 811 green at ship time). Same discipline as round 1: every item
below was confirmed live or by direct inspection today, tina implements,
the driver verifies and commits. Survey sources: the analyzer output,
`.github/workflows/`, git history, and Run U's own transcript.

34. **tool/ carries two probes pinned to an API that never shipped in
    the public tree, plus one superseded driver.** `tool/render_to_image.dart`
    (12 errors) and `tool/visual_test.dart` (3 errors) import
    `package:tina_console/src/panel_layout.dart` / `panel_renderer.dart`
    — neither exists here; the panels API that DID ship is
    `panel.dart`/`panel_content.dart`. Both tools have been
    un-compilable since the initial public release (pickaxe finds no
    commit that ever removed the classes — they predate the repo), and
    they account for 15 of the root analyzer's 32 issues. Same drawer:
    `tool/mute_diag_driver.py`, the first-generation mute driver whose
    read loop stops at the render marker — the exact output blindness
    that cost a diagnosis round on #33 — superseded by
    `tool/syscall_diag_driver.py` (whole-run drain, fd tables, pollfd
    decode, FIONREAD timelines). **Would make:** retire all three. Dead
    code that cannot run misleads more than it documents; git preserves
    them if the panels API ever returns.
    **→ Implemented 2026-08-23 (round 2, driver-side):** all three retired
    (`git rm`); `ARCHITECTURE.md`'s tool/ line updated, and
    `tool/mute_diag_probe.dart`'s header now points at
    `syscall_diag_driver.py` as its companion. Root analyze dropped
    32 → 18 with the fifteen errors gone.
35. **No CI gating: ~2,300 tests and no workflow runs them.**
    `.github/workflows/` contains only `release.yml`. Root 758 + engine
    767 + console 811 tests exist, analyze baselines are tracked by
    hand in this log, and nothing mechanical prevents a red suite or a
    new analyzer issue landing on main. **Would make:** a
    pull_request/push workflow running `dart analyze` + `dart test` for
    root, engine, and console, so this log's "baselines unchanged"
    claims become machine-checked. The analyzer warning inside
    `packages/dart_notcurses` (submodule config) stays out of scope.
    **→ Implemented 2026-08-23 (round 2, tina session
    20260823-145230-d8b5, driver-verified):** `.github/workflows/ci.yml`
    — three plain parallel jobs (root/engine/console; a matrix would
    have needed awkward per-entry `if`s for the root count-gate and the
    console apt step), checkout with `submodules: recursive`,
    setup-dart stable, pub get → analyze → test per package, PR+push on
    main, `contents: read`, no secrets. Root gates by COUNT on
    `dart analyze --format=machine` (verified live: exactly 1 line —
    the submodule's include_file_not_found; fails >1, emits a
    `::notice::` at 0 so the gate gets tightened later). Engine and
    console gate on zero. The apt step's honest nuance, from tina's
    investigation: the bindings load NO system notcurses — the
    submodule's build hook statically links the vendored
    libnotcurses-core.a into a bundled asset; `DynamicLibrary.open`
    appears only in availability probes — so libnotcurses-dev makes the
    probe path real but is not load-bearing for the suite. tina_index
    excluded with a comment until #39 ships. yaml validated; the first
    LIVE runner pass is the remaining acceptance (runner dart SDK, apt
    availability, submodule checkout are only proven on GitHub).
    **→ First live run (32647847129, this PR's update): engine green;
    root + console red — two runner-only facts a dev machine cannot
    show.** (1) The build hook statically links the vendored
    libnotcurses-core.a but leaves `-ltinfo -lunistring -ldeflate` as
    SYSTEM libs, none of whose -dev link symlinks ubuntu-latest ships —
    `dart test` died in the hook with `cannot find -lunistring/
    -ldeflate`; apt list widened to libnotcurses-dev + libtinfo-dev +
    libunistring-dev + libdeflate-dev, in the ROOT job too (root's
    tests import tina_console, so its dart test runs the same hook).
    (2) Root analyze sweeps sub-package test/ dirs, whose test-only
    imports (console's fake_async) resolve only through each package's
    OWN package_config.json — without sub-package pub gets the gate saw
    23 URI_DOES_NOT_EXIST errors; the root job now pub-gets all three
    sub-packages, mirroring a dev machine. Also: #39 shipped in the
    same push, so tina_index joined the matrix (analyze 0 + test 56,
    pure Dart, no apt step) and the exclusion comment is gone.
    **→ Second live run (32648223073): console/engine/index GREEN —
    the linker and package_config fixes held.** Root's analyze gate
    passed too; its `dart test` then lost 17 tests, every one the same
    signature: `ProcessException: Author identity unknown` — the
    summary tests do real `git commit`s in temp repos and a GitHub
    runner ships no git user.name/user.email (invisible locally, where
    a dev machine always has one). Root job now sets a tina-ci identity
    before testing. Third live run is the verdict.
    **→ GREEN 2026-08-23T15:26Z (run 32648458822):** all four jobs —
    root, engine, console, index — success. #35 accepted live; the
    ~2,400-test suite and every analyze baseline are now machine-gated
    on every PR and push to main. Item closed.
36. **Drive the analyzer to zero outside the submodule.** After #34's
    fifteen, eighteen warnings remain (one of them the submodule's
    config warning, out of scope): two `catchError((_) {})`
    handlers whose null return does not match `Future<String>`
    (`lib/host/tui_conversation_host.dart:236`,
    `lib/pipeline/workflow_permission_asker.dart:116` — benign in
    effect, wrong in type), unused imports/declarations and no-op `!`s
    across tina_index (8), console tests (2), engine tests (2),
    `tool/resize_probe.dart` (1), `workflow_permission_asker_test` (2).
    **Would make:** fix the seventeen in-repo ones (return `''` from
    the catchError handlers; drop the dead declarations), leaving only
    the submodule's config warning, then pin zero via #35's workflow.
    **→ Implemented 2026-08-23 (round 2):** tina (session
    20260823-135931-5a3d, six files) + driver completion (eleven more,
    including the store_test.dart bang surgery — only the five
    genuinely-dead `!`s at lines 77/89/99/134/136, after a blanket
    replace broke the twelve that were load-bearing — and the
    scrolling_text_region off-by-one: the newest finished line
    bottom-aligns ON the last row, `height - 1`, not `height - 2`).
    Analyze now: root 1 (submodule only), engine 0, console 0,
    tina_index 0. Suites: engine 767 ✓, console 811 ✓, root 758 ✓;
    tina_index has one failure that predates this work (see #39).
    Driver runs for the next tina session should pass
    `--max-turn-tokens 2000000` — the 1M default was hit a second time
    (1,004,710) during the #36 lint run, again after all substantive
    work, again in closing prose.
37. **The per-turn budget abort beheads a finished run (live, Run U).**
    Run U completed every tool call and test run, then hit
    `[budget] per-turn token budget exceeded (1032509 > 1000000)` in
    mid-final-summary: the closing report the prompt explicitly asked
    for was lost, and the run's tail reads failure-shaped even though
    all work had landed. The #5 fix held (session persisted, resume
    hint printed) — what's missing is a runway. **Would make:** a soft
    margin — at ~90% of `--max-turn-tokens` inject a notice into the
    turn ("turn budget at 90% — finish up and write the closing
    summary") so the model can land cleanly; keep the hard abort at
    100%.
    **→ Implemented 2026-08-23 (round 2, tina session 20260823-142018-6679,
    driver-verified):** `kPerTurnSoftMarginRatio = 0.9` in
    token_budget.dart; `softMarginNotice()` is a pure predicate over the
    same totals `exceeded()` reads (null past the hard cap — the hard
    reason wins); the agent latches it once per turn, resets it at the
    top of `_runTurn`, and delivers the nudge as a user-role message
    injected into the turn's history — the channel that actually
    reaches the model (#27 lesson; tina confirmed independently that
    `sink.notice` is UI-only) — with a `sink.notice` mirror for the
    transcript. Eight regression tests assert wire-level visibility
    (FakeProvider.calls), once-only, ordering before a hard abort, and
    no-op under 90%. Engine: analyze 0, 775/775. Third incident, for
    the record: the run that IMPLEMENTED this hit
    `2013851 > 2000000` — the abort landed after the implementation was
    complete ("The implementation is solid"), during log-editing prose;
    the running process had compiled agent.dart at startup and could
    not hot-load its own fix. The margin's first live beneficiary is
    the next run.
    **→ Verified live, same day:** the very next run (tina session
    20260823-145230-d8b5, the #35 run) hit the margin for real —
    `[budget] turn spend at 90% (1822439 of 2000000 tokens) … write
    your closing summary now` fired mid-run — and the model heeded it:
    final acceptance check, closing summary, clean exit 0. The exact
    beheading this item was written for did not happen.
38. **bash_tool's cap test remains order-dependent (multi-day,
    unreproduced today).** The "output above the cap" test has failed
    in full-suite runs across several days while passing in isolation;
    today it passed four consecutive full engine suites (two driver
    runs, tina's Run U, and the pre-work baseline), so the trigger is
    rare. **Would make:** root-cause the shared state, or make the test
    self-sealed (unique sentinels per run, explicit temp dir) if the
    interference path can't be isolated.
    **→ Root-caused and fixed 2026-08-23 (round 2, driver-side):** there
    never was shared state or order dependence — the "order" theory was
    an artifact of nobody looping the test in isolation. The negative
    assertion `isNot(contains('A'))` reads the spill path that rides in
    the content (`full output: /tmp/tina_bash_test_<suffix>/…`), and
    Dart's `createTemp` random suffix is mixed-case alnum — measured:
    3000/3000 suffixes contain uppercase, ~21% contain 'A'. The test
    failed on ~20-25% of runs regardless of context (5/20 looped
    pre-fix; the day's four passes were p≈.8 luck). Fix: sentinels
    outside every alphabet involved ('!' head / '#' tail — not in
    headers, not in the path suffix), with the constraint documented at
    the assertion. Post-fix: 0/30 looped failures.
39. **tina_index's `seedQuery "stream" returns streaming-related symbols`
    fails on pristine HEAD — pre-existing, not lint collateral.**
    Verified by control: the failure reproduces with the working tree
    hard-reset to HEAD (only `/tmp/index_lint.patch` as a cross-check),
    so it predates round 2 entirely; it was simply never in any
    baseline run before today, because tina_index's suite wasn't part
    of the driver's routine gate. **Would make:** reproduce, diagnose
    whether it's a seed-corpus or a query-semantics bug, and fix —
    then add tina_index to the suites this log tracks (and to #35's
    workflow matrix), so a red test there never ships un-noticed again.
    **→ Diagnosed 2026-08-23 (round 2, driver-side):** not a flake — the
    test scans the LIVE tree (`GraphStore.rebuildFromRepo`), and round
    1's `streamIdleTimeout` field (added to Config + six providers and
    the scheduler) outranks it everywhere: `seedQuery` scores
    name-prefix hits 500 but camelCase-fragment hits only 300, so seven
    bearers of the same member name take seven of the ten slots while
    `ProviderStreamConsumer` (300 − 78 ≈ 222) falls off the bottom. The
    ranker is the defect — a seed query feeds the agent context anchors
    and wants diversity, not seven copies of one field name. Fix:
    dedupe results by bare symbol name (keep the highest-scoring
    bearer), collapsing the seven to one and letting StreamConsumer
    back in without touching the test's expectation.
    **→ Fixed 2026-08-23 (round 2, driver-side):** seedQuery now sorts
    by score, then keeps only the best-scoring bearer of each bare
    symbol name before take(maxResults); a synthetic-table regression
    test ('one slot per bare symbol name, however many bearers') pins
    it without depending on the live tree. tina_index: analyze 0,
    56/56 tests green — the suite joins the driver's routine gate
    (and CI's matrix once #35's workflow lands).

## Improvements run, round 3 — fresh backlog (2026-08-24)

PR #19 was squash-merged to main as c607c37 ("Recursive improvement
round 2: … (#19)"); CI ran green on the merged content's twins (run
32648458822, all four jobs), and the working branch was reset onto
main's tip to start this round clean. Same discipline: every item below
confirmed live or by direct inspection today; tina implements what it
can, the driver verifies and commits.

40. **Root analyze's ONE remaining issue is the submodule's config, and
    the parent tree can silence it parent-side.** The warning
    (`include_file_not_found` at packages/dart_notcurses/
    analysis_options.yaml:1:10) fires because the submodule's options
    file includes `package:lints/recommended.yaml` while the parent
    tree's analysis context has no `lints` package; the parent repo has
    NO analysis_options.yaml of its own (pure SDK defaults), so the
    analyzer reads the submodule's config for the files it sweeps. The
    submodule is out of scope to edit (standing rule), but the PARENT
    can exclude it: a root analysis_options.yaml with
    `analyzer.excludes: [packages/dart_notcurses/**]` stops the sweep
    from loading that config at all. **Would make:** add the root
    options file with the exclude (documented with why), verify root
    analyze reaches 0, then tighten ci.yml's root gate from the
    count-based tolerance (==1) to plain zero — removing the
    count-gate's special case and its `::notice::` exactly as the
    workflow's own comment planned ("when the warning disappears,
    tighten this gate to plain `dart analyze`").
    **→ Implemented 2026-08-24 (round 3, driver-side):** root
    analysis_options.yaml created with `analyzer.exclude:
    packages/dart_notcurses/**` (first attempt used `excludes` — the
    analyzer rejected it with `unsupported_option`, which SURFACED a
    second warning while leaving the first; the supported key is
    `exclude`). Root analyze: **No issues found!** — zero for the
    first time in the repo's history. ci.yml's root gate tightened
    from the count-based tolerance to plain `dart analyze`, with the
    count-gate's history kept in the step comment. Engine, console,
    and tina_index re-verified at 0 after the change.
41. **The incremental Git-Data-API push tool lives only in /tmp.**
    tool/push_via_api.py (in-repo) pushes a range but has no
    remote-parent grafting and — as this round's first shipment
    learned — no deletion handling (`git ls-tree` on a removed path
    returns empty and the blob-upload loop dies with IndexError). The
    incremental variant (/tmp/push_inc.py, adapted from that tool)
    grafts each new commit onto the remote twin of the local base and
    skips empty ls-tree results; it carried round 2's entire shipment —
    six replicated commits across two batches INCLUDING deletions
    (9305e6b removed three tool/ files) and three CI fixes. **Would
    make:** land it as tool/push_incremental.py next to its parent
    tool, with the deletion-skip and the grafting documented in the
    docstring, so the next round's shipment does not depend on /tmp
    surviving.
    **→ Implemented 2026-08-24 (round 3, driver-side):** landed as
    `tool/push_incremental.py` (executable, docstring covering the
    grafting and the deletion skip); the code body is the /tmp version
    that carried round 2 — the deletion skip, the remote-parent graft,
    and the 422 ref fallback all verified present. Round 3's own
    shipment (this commit) is its first in-repo use.
42. **What actually consumed the 2M-token turn is unmeasured.** Three
    runs hit the per-turn cap (1,032,509 / 1,004,710 / 2,013,851), the
    soft margin fired at 1,822,439 and the model landed clean — #37
    treats the symptom. But WHY a task brief plus ~30 steps costs two
    million tokens has never been measured: candidates are verbatim
    tool outputs (full `dart test` suite runs entering history), whole-
    file reads of large sources, and the conversation's own growth
    re-sent on every step. The engine records per-call usage. **Would
    make:** evidence first — analyze the two aborted sessions'
    transcripts (20260823-142018-6679 and the 2M #36 run) plus the
    1.82M #35 run, break spend down by contributor, and only then
    propose the fix (tool-output compaction, read sizing, or a tuned
    auto-compact trigger) as a future item with numbers attached.
    **→ Investigated 2026-08-24 (round 3, driver-side) — the numbers are
    in, and they indict re-sent file reads.** The 1.82M #35 run's
    persisted transcript (.tina/sessions/…145230-d8b5, 73 messages, 45
    tool calls): final history 228KB ≈ 57K tokens, of which **88% is
    tool_result bodies** (assistant prose 2%, tool_use 6%). The
    largest results are READS, not test output — the lean-brief
    strategy (driver runs the suites) worked: read of
    TINA_IMPROVEMENTS_LOG.md 53KB, notcurses_backend.dart 38KB,
    dart_notcurses lib 30KB, release.yml 12KB, a console grep 11KB.
    Arithmetic: cumulative spend = steps × context — 45 calls at an
    average ~35-40K input (growing to 57K) + per-call system ≈ the
    measured 1.82M within ~15%. One number tells the story: the single
    53KB log read is ~13K tokens re-sent on every subsequent step —
    **45 × 13K ≈ 585K tokens, ~32% of the entire turn, from one
    read**. The 2M aborted run shows the same shape one step further:
    its transcript OPENS with a compaction summary (request-size
    auto-compact fired when a request crossed 120K), growth slowed,
    and the turn still died at 2M — compaction-by-request-size cannot
    fix spend that is cumulative-by-construction. This confirms item
    #9's original diagnosis with measurements. Future items, numbers
    attached: (a) turn-level compaction keyed on CUMULATIVE spend —
    compact when turnTotal crosses ~50% of perTurnLimit; (b) age
    tool_result bodies out of history — after K steps, replace an old
    large read with a stub ("[read of <path>, N lines — re-read if
    needed]"), bounding steady-state context to recent results plus
    the model's own prose.
