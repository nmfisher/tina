---
id: tin-r6km
status: start
deps: []
links: []
created: 2026-09-10T00:00:00Z
type: feature
priority: 1
assignee: Nick Fisher
tags: [plugin-runtime, composition, refactor, agent, tools]
---
# Plugin runtime — shared lifecycle for built-in features

## Context

`docs/proposals/plugin_runtime.md` (2026-09-10) plans Tina's built-in features
as plugins with one lifecycle: typed service dependencies, owned registrations,
explicit execution hooks, and a replaceable agent driver. A01–A08 are done and
the working tree holds the runtime read-all + environment-phase gates, which
land first as the baseline. External package discovery, downloads, WASM, a
public SDK, and live code replacement are explicitly out of scope.

Implementation order is the proposal's P0–P8. The recommended starting slice is
P0 + P1, then P2/P3 before any UI or public profile surface.

## Task

Implement the proposal phase by phase. Each phase is a separate reviewable
commit on `asb/plugin-runtime`. Tina (driven through the `tina-pool` /
`zai/glm-5.3-flash` model pool) writes the code; the orchestrating session
verifies and ships.

## Agent rules

- Backend: notcurses only. Never fall back to `--backend ansi`.
- Verify with `dart analyze`, the touched package's `dart test`, and
  `dart tool/check_architecture.dart` when dependencies move.
- Commit all work locally on `asb/plugin-runtime`. Push the branch and raise a
  PR when finished. Never merge the PR. Never commit or push to main.
- Update this ticket with tk: start when you begin, close when done.

## Acceptance Criteria

- Engine runtime primitives exist and cannot import app, terminal, or concrete
  tool code; `tina_console` stays independent of the runtime.
- Provider construction and metering mount as the first runtime plugins; failed
  startup leaves no resources; providers close once.
- Tool catalog, execution pipeline (guards, approval, sandbox, cancellation),
  prompts, and driver route through the new contracts, with behavior preserved
  against the pre-change baseline (byte-identical tool schemas and system
  prompt, unchanged session format).
- Architecture ratchet passes without broad new exceptions.

## Result

Started 2026-09-10. `tk` is not installed in this container (same as
tin-h8uw/tin-vb4k), so status changes land as frontmatter edits here.

Progress log (updated as phases land):

- P0 done: baseline green everywhere; creation/cleanup paths inventoried.
- P1 done: engine runtime primitives (contracts, plugin, runtime) + 30
  tests; RuntimeResources aliased to ScopeResources; ledger + provider
  factory mounted as the first execution plugins.
- P2 done: ProjectCapabilities split; per-tool plugins behind a frozen
  catalog; ProjectToolScope consumes an internal plugin runtime; app
  mounts capabilities + scope as plugins (borrow path untouched).
- P3 done: ToolExecutor extracted verbatim from agent.dart; guards are
  deny-preserving contributions (policy + phase first, extras additive);
  typed hooks (around / post-tool / observation) with the verifier and
  sink adapters as built-in consumers.
- P4 done: system prompt assembled from ordered contributors
  (byte-identical); provider decorators are ordered contributions around
  the always-present metering layer.
- P5 done: AgentDriver contract + default adapter; both plain scheduler
  builds route through it; Conversation and TurnExecutor speak to the
  driver; SessionManager/restore take a driverWrapper seam.
- P6 done: driver/persistence factories mount at the composition
  (createScheduler -> buildExecutionRuntime -> buildAppComposition); null
  defaults keep the built-in loop and in-memory transcripts.
- P7 in progress: PluginRuntime.describe() diagnostics + the default
  execution profile extracted from buildExecutionRuntime, overrides
  validated before any factory runs.

