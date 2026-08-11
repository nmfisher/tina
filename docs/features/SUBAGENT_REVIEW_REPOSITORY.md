# Per-Directory Summary Sidecar (agent fleet)

> **Status update (2026-07-15):** the separate `bin/refresh_summaries.dart`
> entry has been **removed**. Refreshing the sidecar is now the in-app
> **`/index`** session command (and the headless `tina --prompt /index`),
> driven staleness-aware: nothing stale → report up to date + confirm (y/n in
> the TUI; headless reports and stops) before a full re-run; partly stale →
> report the stale dirs and re-run just those; first run / all stale → index
> all. The dance lives in `runIndexDance` (`lib/session_commands/...`); the
> new façade `lib/summaries/summary_index.dart` (`SummaryIndex.status` /
> `.refresh`) wraps `SidecarSummaryRepo` + `SummaryRunner` and is wired onto
> `CommandContext` from `TuiCoordinator.create` (and `_runNonInteractive`).
> Everything below is the original design doc; the `bin/refresh_summaries.dart`
> CLI entry it describes is superseded by `/index`.
>
> **Status update (2026-08-11):** the sidecar is no longer a pure sink — it now
> feeds **region agents**: the main agent can allocate a sub-agent to any
> subfolder, primed with its persistent summary (loaded at session start, zero
> LLM calls), and route scoped questions to it (`query_region` /
> `broadcast_region`). See the "Region agents" section below. (The `summarizer`
> role section further down predates the delegate-catalog removal — summarizers
> are today read-only sub-agents with `write_summary`, per commit `d7be7cd`.)

## Region agents

The main agent gets a region surface built over the sidecar
(`lib/regions/`): regions are the default partition **plus** any directories
the main agent allocated, each primed with its summary text.

- **Priming is free**: `RegionRegistry` (`lib/regions/region_registry.dart`)
  reads the manifest + summary files at session start — pure file/git reads,
  no backend calls. Regions are logical entities; an agent only runs when a
  query is dispatched.
- **Allocation** (`allocate_region` / `forget_region` tools) writes
  `allocations.json` in the sidecar root (a separate file from `manifest.json`
  so the summary schema is untouched) — the partition becomes
  `defaultPartition() ∪ allocations` (`SummaryIndex.partition`). Allocating
  fires a **single-dir fleet refresh** (`SummaryIndex.refresh(dirs: [dir])`,
  fire-and-forget) so the summary lands shortly after.
- **Queries** (`query_region`, `broadcast_region`) dispatch one-shot read-only
  agents via `SubAgentScheduler.runStandalone(toolProfile: readOnly,
  includeDelegate: false)` (new params, defaults unchanged): identity = the
  region + its summary + a staleness warning, tools = read/search/grep/glob +
  `write_summary` (so a region agent can refresh its own summary after
  substantive work), model = allocation override ?? `[regions] model` ??
  inherit. **Scoping is soft** (the prompt pins the region; there is no
  per-agent cwd in the engine) — hard per-region sandboxing is future work.
- **Staleness is visible, never auto-refreshed**: `list_regions` /
  `read_summary` flag a region whose tree hash drifted (the existing pure-git
  probe), so the main agent can run `/index` before trusting a stale summary.
- **Config**: `[regions] model = "provider/model"` sets the fast tier default;
  per-region overrides ride the allocation.

## Context

We want a fleet of agents, each owning a subdirectory, that writes a prose
summary of the files in that directory. The summaries must live **outside** the
main git repo (so they don't clutter code diffs) but **track** it: when code in
a directory changes (added / deleted / modified), that directory's summary is
invalidated and regenerated — and only that one.

Today tina has `SummaryGenerator` + `bin/generate_summaries.dart`, but that
system is **per-symbol**, stored in the gitignored `.tina/graph.json` blob —
not version-controlled, not pinned to a main-repo commit, not per-directory, and
not driven by the agent fleet. This plan adds the per-directory, sidecar-tracked,
fleet-driven layer **without disturbing** the existing per-symbol system.

### What already exists (reuse, don't rebuild)
- **`orchestrator` role** (`packages/tina_engine/lib/src/agent/agent_pipeline.dart:273`) — `canDelegate: true`, `modelTier: 'heavy'`, read tools. Fans out via `delegate`.
- **`scout` role** (`agent_pipeline.dart:283`) — read-only (`read/search/grep/glob`), `modelTier: 'light'`, identity: *"summarizes one codebase segment."* This is the summarizer, almost verbatim.
- **`DelegateTool`** (`packages/tina_engine/lib/src/tools/delegate_tool.dart`) — one `delegate` call takes a `delegations` array of `{"agent","task"}` and runs them **concurrently** via `Future.wait` (`delegation_base.dart:119`). Per-call cap `kMaxDelegations = 8`; the model retries in batches.
- **`HeadlessHost`** (`packages/tina_engine/lib/src/host/headless_host.dart`) + **`buildAppComposition`** (`lib/composition/app_composition.dart:73`) + **`buildAgent(withSubAgents: true, system: ...)`** (`lib/composition/agent_composition.dart:44`) — the headless fleet path, already used by `bin/tina.dart`'s `_runNonInteractive` (`bin/tina.dart:147`).
- **`git rev-parse HEAD:<dir>`** — gives a stable per-directory tree hash (verified: `git rev-parse HEAD:lib` → `5e0e229…`). Cheap invalidation key, no AST needed.

### Decisions (confirmed with user)
- **Partitioning**: deferred to the orchestrator later. v1 uses a deterministic default partition (top-level dirs + `packages/*/lib`); the orchestrator's job in v1 is to fan out one summarizer per stale dir.
- **Tracking model**: *record main commit hash* — the sidecar commits independently; each summary records the main-repo `HEAD` sha + the dir's tree hash. No hooks, no per-commit mirroring.
- **Sidecar location**: `.tina/summaries/` as its own git repo. `.tina/` is already gitignored (`.gitignore`), so it's fully outside the main repo's tracked tree. No config-schema bump.
- **Execution**: real sub-agent fleet via `SubAgentScheduler` + `DelegateTool`.

## Design

### Sidecar repo layout (`.tina/summaries/`)
```
.tina/summaries/
  manifest.json          # authoritative partition + per-dir {commit, tree, file}
  lib.md
  packages__tina_index__lib.md
  ...
```
- One markdown file per directory; path slugs replace `/` with `__`.
- Each file header: `<!-- tina-summary dir="lib" commit="<sha>" tree="<treehash>" generated="<iso8601>" -->`.
- `manifest.json`: `{ "dirs": { "<dir>": {"commit","tree","file"} } }`. The set of keys **is** the partition — stable across runs.
- Initialized with `git init` on first run; commits via `git -C .tina/summaries add -A && commit -m "summaries @ <short-sha>: <stale dirs>"`. Summaries reflect main-repo `HEAD` (committed state), not the working tree — matches "record main commit hash."

### Invalidation (deterministic, in the driver — not the LLM)
For each dir in the manifest:
- `git rev-parse HEAD:<dir>` → current tree hash.
- Missing → dir deleted: remove its summary file + manifest entry.
- Differs from `manifest.tree` → stale → regenerate.
- New dirs (in default partition, not in manifest) → generate.
Empty stale set ⇒ exit "up to date". This is the "only regenerate when code in *that* dir changes" guarantee.

### New `summarizer` role + `WriteSummaryTool`
Rather than parse merged orchestrator text, each summarizer **writes its own
summary file** through a constrained tool — clean per-file capture, no fragile
text parsing.

- **`WriteSummaryTool`** (`packages/tina_engine/lib/src/tools/write_summary_tool.dart`, new):
  - Schema: `{ "dir": string, "content": string }`.
  - Holds the sidecar root (injected at composition, like the sandbox in `configureToolSandbox`, `agent_pipeline.dart:170`).
  - At execute time, runs `git rev-parse HEAD` and `git rev-parse HEAD:<dir>` itself for the header (always correct, unforgeable by the child).
  - Writes `<sidecar>/<slug>.md` atomically (reuse `AtomicWrite` / `write_tool.dart`'s pattern). Read-only w.r.t. the main repo — it can only touch the sidecar path.
- **`summarizer` role** (new, `agent_pipeline.dart`): `tools: {_read, _grep, _glob, writeSummary}`, `modelTier: 'light'`, identity = scout's prose + "write your summary via `write_summary(dir, content)`." Add the shared singleton `_writeSummary` alongside `_read`/`_grep`; configure its sidecar root in `configureToolSandbox` (derive from `tinaDirFromEnv(env)` → `<tinaDir>/summaries`). Register the role in `defaultPipeline.roles`.
- Because the scheduler derives each role's allowed permissions from its `tools` (the `_policyFor` rule, per the sub-agent-permissions invariant), adding `WriteSummaryTool` to the role's `tools` automatically permits `write_summary` — **no manual policy widening**. Summarizers get no `write`/`edit`/`bash`, so they cannot touch the main repo.

### Headless fleet driver
**`lib/summaries/sidecar_repo.dart`** (new): `SidecarSummaryRepo` — `init()`, `loadManifest()`, `staleDirs(partition)` (runs the `git rev-parse` diff above), `commit(dirs)`. Pure `Process.runSync('git', ...)`; no LLM.

**`lib/summaries/summary_runner.dart`** (new): the orchestrator driver.
1. `buildAppComposition(config)` (reuse — gives `pipeline`, `scheduler`, `provider`, `policy`).
2. Configure `WriteSummaryTool` sidecar root (via the same composition hook).
3. Build a headless agent: `buildAgent(pipeline, scheduler, ..., withSubAgents: true, system: <summarization orchestrator prompt>)` — the top agent has only `delegate`+channels (no file tools, structurally), which is exactly what we want; the user prompt lists the stale dirs + their tree hashes and instructs: *"for each dir, delegate to `summarizer` with task 'read and summarize <dir>'; batch ≤8 per `delegate` call."*
4. `agent.run(history: [], userInput: <stale-dir list>)` against a `HeadlessHost`.
5. Each `summarizer` child reads its dir and calls `write_summary` → files land in the sidecar.
6. After `run`: `SidecarSummaryRepo` updates `manifest.json`, then `git add -A && commit`.

**`bin/refresh_summaries.dart`** (new, mirrors `bin/generate_summaries.dart`): parses `--dry-run` (report stale dirs only, no LLM), `--repartition` (clear manifest, regenerate all), `--base-url/--model` (defaults from env, same as `generate_summaries.dart:9-14`). Calls `SummaryRunner`.

### Why a custom orchestrator `system:` prompt
`buildAgent`'s `system:` param overrides the resolved identity, so we reuse the
`orchestrator` role's tools/delegate capability without its code-change
choreography (plan-writing, review loops). The override is local to this run —
it does not alter the interactive `orchestrator` role or `[prompts.orchestrator]`
config.

## Files
**New**
- `packages/tina_engine/lib/src/tools/write_summary_tool.dart` — `WriteSummaryTool`.
- `lib/summaries/sidecar_repo.dart` — `SidecarSummaryRepo` (git wrapper + manifest + staleness).
- `lib/summaries/summary_runner.dart` — headless fleet driver.
- `bin/refresh_summaries.dart` — CLI entry.

**Modified**
- `packages/tina_engine/lib/src/agent/agent_pipeline.dart` — add `writeSummary` singleton + `summarizer` role; register in `defaultPipeline`; configure root in `configureToolSandbox`.
- `packages/tina_engine/lib/tina_engine.dart` (barrel) — export `WriteSummaryTool` (and role if barrel exposes roles).
- `lib/composition/app_composition.dart` or `agent_composition.dart` — ensure `configureToolSandbox` is called with a sidecar root for `WriteSummaryTool` (the headless path already calls it; extend, don't duplicate).

**Tests**
- `packages/tina_engine/test/write_summary_tool_test.dart` — writes to a temp sidecar; header carries correct commit/tree; refuses paths outside the sidecar.
- `test/summaries/sidecar_repo_test.dart` — init, manifest round-trip, staleness detects modified / deleted / new dirs (use a temp git repo).
- `test/summaries/summary_runner_test.dart` — end-to-end with a stub `LlmProvider` that emits one `delegate` call; assert summary files + a sidecar commit exist. (Mirror the headless test patterns — drive `buildAgent`, never a REPL.)

## Verification
1. `dart analyze` + `dart test` (engine + tina suites).
2. `dart run bin/refresh_summaries.dart --dry-run` in this repo → lists stale dirs (all, first run).
3. `dart run bin/refresh_summaries.dart` → produces `.tina/summaries/*.md` + a git commit; `git -C .tina/summaries log` shows one commit; `manifest.json` has tree hashes.
4. Touch a file in `lib/`, commit it in the main repo, re-run → only `lib.md` regenerates; `git diff` in the sidecar is one file.
5. `git rm` a top-level dir, commit, re-run → its summary file is removed from the sidecar and a new commit records the deletion.
6. Confirm main repo `git status` is clean throughout (sidecar is under gitignored `.tina/`).

## Out of scope (follow-ups)
- Orchestrator-decided partitioning — partially delivered: the main agent can
  now allocate arbitrary directories (`allocate_region`); automatic partition
  proposals remain future work. The manifest + `allocations.json` are the
  stable pins.
- A `/summaries` session command + TUI viewer (browse/regenerate from the chat).
- Pushing the sidecar to its own remote.
- Per-symbol `SummaryGenerator` is untouched; the two systems are complementary.

## Open question for the user
Summaries reflect **committed** `HEAD`, not the working tree — so uncommitted
edits won't trigger regeneration until committed. That follows from "record main
commit hash," but a `--include-dirty` mode (hash the working-tree dir instead of
`HEAD:<dir>`) is possible if wanted.
