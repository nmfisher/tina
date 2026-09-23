# PT0 — Launcher-conditional plugins + explore_project

Status: proposed.
Prerequisites: none.
Index: [README.md](README.md).

## Problem

Two remnants are outside the plugin scope even though nothing about them
needs a conversation:

1. `bin/tina.dart` encodes plugin-mounting policy inline:
   `if (!launch.startup.nonInteractive) configuredGitInputPlugin(...)` etc.
   The launcher decides *for* the plugin instead of the plugin deciding for
   itself, which is the opposite of the target shape.
2. `explore_project` is constructed in the launcher
   (`createConfiguredExplorationTool`) and threaded by hand through
   `bin/tina.dart` → `TuiCoordinator` → `buildAgent` → every caller that
   passes `exploreProject:`. Its dependencies (env, spend ledger, pause gate)
   are all process-scoped — the same shape as `web_search`, which already
   crosses the scope correctly.

## Implementation

**Conditional plugins self-gate.** Each currently-conditional descriptor
gains a factory that contributes nothing when its condition fails:

- git/intent input: the factory returns `Object()` without registering when
  a headless marker is present. Thread one boolean (`interactive`) through
  `buildAppComposition` as a plain parameter, or have the launcher pass an
  env-derived flag the factories already read — prefer the explicit
  parameter; env flags are how `web_search` keys work and these are not
  secrets. The `if (!nonInteractive)` lines disappear from `bin/tina.dart`.
- The session-store conditional (`providesSessionStore` check) is already
  composition-side and correct per SP1's landed correction — leave it.

**explore_project becomes a contribution.** New built-in plugin
`tina.tool.explore-project` (id sorts after `tina.tool.web-search`; it is a
registry tool, not a base-catalog tool, so `kWorkspaceToolCatalog` is
untouched and the catalog rank in `toolRegistryFromScope` keeps it after the
frozen fourteen). The factory needs `env`, `spendLedgerServiceKey`, and the
pause gate — the ledger is a `require`; env and gate ride the composition
the way `workspaceCapabilitiesPlugin` already receives them.

Delete the `exploreProject:` parameter from `buildAgent` and the
`createConfiguredExplorationTool` threading; `agent_composition` picks the
tool up from the scope like every other registry tool. The orchestrator
allowlist (`orchestratorTools` / `OrchestratorToolGuard`) reads it from the
same scope — the guard's name check is unchanged, so orchestrators remain
fail-closed.

The headless path in `bin/tina.dart` (`_runNonInteractive`) currently builds
its own `explore_project` for a driver that bypasses `buildAgent`'s scope
read; it switches to the scope lookup too (the composition's scope is
already in hand there).

## Migration

1. Self-gate the git/intent plugins; drop the launcher conditionals.
2. Add `tina.tool.explore-project`; switch `buildAgent`, the orchestrator
   assembly, and the headless driver to scope lookup.
3. Remove the `exploreProject:` parameter and `createConfiguredExplorationTool`
   call sites.
4. Capture the four shape goldens (tool names + policy table) as tests.

## Validation

- Golden tests (README invariant) pass unchanged.
- Headless run: no git/intent contributions registered (assert scope empty
  of them); interactive: both present.
- Orchestrator turn: `explore_project` reachable, all other tools blocked by
  the guard (existing orchestrator tests stay green).
- `dart analyze` clean; full suite green.
