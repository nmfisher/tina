# Internal extension seams — refactor plan (pre-`plugin_architecture`)

**Status:** Proposal only — no code or test changes. **Revised 2026-08-29** after
owner scope correction: this is a **refactor/restructure plan**, not a plugin
system.
**Date:** 2026-08-29 (revised; original plugin-system proposal superseded)
**Author:** Nick Fisher

## 1. Goal, and what this is not

Introduce clean **internal extension seams** — registration points and
lifecycle hooks for workflows, panels, providers, commands, and turn-lifecycle
events — and **decouple tina's own built-ins through them**. The refactor is
internal and invisible to users: no behavior change, no config surface, no new
flags, no new packages beyond what the refactor itself requires.

**Explicit non-goals (all deferred, none designed here):**

- No plugin loader, no `tina_plugin_api` package, no user-facing API.
- No config surface (`[plugins]` TOML, CLI flags, trust prompts).
- No WASM runtime, WIT definitions, or FFI host — see §9 for how the seams
  keep that door open without building any of it.
- No new user-visible behavior, including error-message wording or startup
  output.

The test of sufficiency for every seam: **tina's built-ins migrate onto it and
nothing user-visible changes.** If a built-in cannot move without a behavior
change, the seam is wrong or the migration is out of scope.

## 2. The design constraint that shapes the seams

The long-term destination is that third parties compile plugins (likely to
WASM) and tina hosts them. We build none of that now, but it dictates the
*shape* of the internal seams, the same way a future network transport
dictates that an internal interface pass data, not live object graphs:

1. **Data-oriented boundaries.** Seam edges carry plain records (name, spec,
   payloads) — not concrete UI widgets, not backend handles, not singletons.
2. **Capability-scoped consumers.** A consumer receives an explicit, narrow
   context (the registries it may write, the read handles it may use) from
   the host — never global state. Today that context is assembled at
   composition; later a WASM host serializes the same scopes.
3. **Host owns registration and dispatch.** Consumers register records; the
   host (composition root) iterates, orders, and contains errors. No consumer
   reaches into another consumer.
4. **Error containment at dispatch sites.** One hook subscriber or command
   handler failing must not break the turn/boot. This is cheap insurance
   internally and mandatory across a sandbox boundary later.

Anything beyond these four rules is speculative generality and is out of
scope.

## 3. Current state (why each seam is needed)

| Surface | Today | Anchor |
| --- | --- | --- |
| Commands | static `switch (word)` dispatch; the `/help` text list is maintained by hand | `lib/session_commands/session_command_handlers.dart:64` |
| Lifecycle hooks | no first-class concept; events are ad-hoc (`StreamEvent`, spend ledger, audit/redaction, `_chatSink` beginAssistantTurn) | — |
| Providers | already registry-based: `ProviderBuilder` / `ProviderDecorator` typedefs, resolution at composition | `packages/tina_engine/lib/src/llm/registry.dart:97,104` |
| Workflows | DOT graphs load from files; node kinds are handled by built-in handler types in the runner; `launch_workflow` / `default` seeding are hardcoded | `lib/pipeline/` (`pipeline_runner.dart:33`, `workflow_names.dart`, `default_workflow.dart`, `launch_workflow_tool.dart`) |
| Panels | panel system with focus/input routing exists (`tina_console`), but consumers construct specific panels directly; the workflow run panel is built inline | `packages/tina_console/lib/src/panel.dart:24`; `runPanels` at `lib/tui_coordinator.dart:1311-1420` |
| Layering | `tina_engine` ← siblings (`tina_console`, `tina_index`) ← root app; `test/import_boundary_test.dart` forbids engine importing TUI packages | enforced |

Asymmetry to exploit: providers are **already** the target shape — the
provider work below is hardening and uniformity, not new architecture.

## 4. The seams

Each subsection: the internal abstraction, what migrates onto it, and how the
no-behavior-change invariant is tested. Registries are internal to the package
that owns the surface (`src/`-private, exported only to the composition root
where the layering already allows it).

### 4.1 Command registry (root app)

- **Abstraction:** `SessionCommandRegistry` — ordered map of command name →
  command record (`name`, `argsHelp`, `summary`, handler closure over
  `CommandContext`). A `register()` at composition replaces the static
  dispatch: the `switch` at `session_command_handlers.dart:64` becomes a
  lookup + invoke with the same precedence and unknown-command wording.
- **Migrates:** every built-in slash command (`/spawn`, `/detach`, `/help`,
  `/models`, …). `/help` renders from the registry, deleting the hand-kept
  list.
- **Tests:** existing command tests pass unchanged; new test asserts registry
  order == old switch order and that `/help` output is byte-identical to
  today's (golden snapshot).

### 4.2 Lifecycle event bus — DEFERRED (survey finding, 2026-08-29)

The planned abstraction — typed, observe-only event records with a subscribe
API (`sessionStart/End`, `turnStart/End`, `beforeToolCall`, `afterToolResult`,
`modelResponse`), host-side registration-ordered dispatch, per-subscriber
error boundary — is **deferred until a real subscriber exists** (e.g. the
future WASM host, or a new audit/telemetry consumer). The survey falsified the
migration premise: every observation-shaped listener this section named is
already seam-shaped —

- the audit/redaction tap is already centralized through one function
  (`auditDenial`, `packages/tina_engine/lib/src/tools/audit.dart:25`; its doc
  comment: "this isn't a free-form event bus");
- spend-ledger updates flow through the `MeteringProvider` decorator
  (`packages/tina_engine/lib/src/llm/metering_provider.dart:45`), i.e. the
  existing `ProviderDecorator` seam;
- the chat sink (`onCapped`/`onRawText`) is an owned protocol object, not a
  loose listener.

Building the bus now would land a seam with no consumer — the exact
speculative-generality failure §7.1 warns about. The design above is
preserved as the shape to build when the first subscriber appears.

### 4.3 Workflow graph + node-kind registries (engine/app boundary)

- **Abstraction:** two small registries.
  - *Graph registry:* name → DOT source (or parsed graph), seeded at
    composition. `launch_workflow` resolves through it; the seeded `default`
    graph becomes a registry entry instead of a hardcoded name.
  - *Node-kind registry:* DOT node handler kinds → executor. Today the
    runner's handler types are effectively a closed enum; the registry makes
    the seam explicit without adding any new kind. Executors receive the
    capability-scoped context they already receive (per-node input, host
    handles) — no signature change, just indirection through the registry.
- **Migrates:** `default.dot` seeding, `workflow_names.dart` validation
  (names resolve from the registry), `launch_workflow_tool` help text
  enumerates registry contents.
- **Tests:** existing pipeline suites green; golden test that `launch_workflow`
  help output and `default` resolution are unchanged.

### 4.4 Panel provider seam (tina_console)

- **Abstraction:** a narrow internal factory — `PanelHost` with
  `openPanel(PanelSpec)` where `PanelSpec` is a plain record (title,
  placement hint, update sink). Panel **consumers** (workflow run panel,
  future built-ins) obtain panels through the host instead of constructing
  concrete `Panel` subclasses inline. The `Panel`/`Region`/`Focusable`
  class hierarchy stays exactly as it is; the seam is one level above it.
- **Migrates:** the workflow run-panel creation site
  (`lib/tui_coordinator.dart:1311-1420` `runPanels`). Nothing else in v1.
- **Constraint honored:** no notcurses or backend types appear in
  `PanelSpec` — the record is renderable by both backends (SGR-tagged rows),
  matching the placement rules already locked in
  `docs/features/terminal_panel_plan.md`.
- **Tests:** TUI suites green; the run panel behaves identically (existing
  coordinator tests).

### 4.5 Provider registry — hardening only (engine)

- **Abstraction:** none new — `registry.dart` already is the seam. Work is
  uniformity: composition routes *all* provider construction (default,
  pooled, environment overrides) through the same resolution path; the
  `ProviderBuilder`/`ProviderDecorator` contracts get the doc comments and
  negative tests (throwing builder, resolution failure) that the other
  seams get.
- **Migrates:** nothing user-visible; a few call sites converge.
- **Tests:** existing registry/pool suites green.

## 5. Sequencing (internal PRs, each independently revertable)

| Step | Slice | Size |
| --- | --- | --- |
| 1 | Command registry + built-in migration + `/help` from registry | small |
| 2 | Workflow **graph catalog** + node-kind seam hardening (the node-kind registry already exists in attractor — `NodeHandlerRegistry`) | medium |
| 3 | Panel host seam + run-panel migration | medium |
| 4 | Provider-path uniformity + cross-seam doc pass (`docs/features/` additions only where behavior-neutral) | small |

Order rationale: commands are the smallest closed set and prove the
registration pattern; workflows follow (their catalog has real hardcoded
consumers); panels next; providers last because least needs doing. The event
bus is not sequenced — it lands when its first consumer appears (§4.2).
Resequenced per owner decision 2026-08-29 after the consumer survey. Each
step keeps all suites green and lands no config/CLI diff.

## 6. Invariants (checked per step)

- No user-visible change: CLI `--help`, `/help` output, startup output,
  config parsing, error wording — byte-identical (golden tests where cheap).
- No new public API: everything lands `src/`-private or app-internal;
  `test/import_boundary_test.dart` unchanged and passing.
- No new dependencies.
- `dart analyze` clean in engine + root; full root + engine suites green.
- Leak ritual on every commit (standing rule).

## 7. Risks and tradeoffs

1. **Speculative generality.** The failure mode of "build seams for a future
   plugin system" is seams nobody consumes. Mitigation: every seam lands
   *together with* its built-in migration (dogfooding is the acceptance
   criterion), and the four boundary rules in §2 are the only future-facing
   constraints.
2. **Indirection tax on the hot path.** The command dispatch and event
   dispatch gain a registry hop. Negligible at this scale, but the event bus
   is deliberately allocation-light (typed records, no dynamic).
3. **UI churn risk.** The panel seam touches `tui_coordinator.dart` (2885
   lines). Mitigation: the seam is one factory boundary above `Panel`; the
   `Panel` hierarchy itself does not move.
4. **Behavior-drift in migrations.** `/help` and `launch_workflow` help text
   are the likeliest silent drift points; both get golden tests in the same
   PR as the migration.

## 8. Why not just wait for the WASM work

Deferring the seams to the plugin project would couple two hard things:
designing the plugin surface *and* untangling the built-ins at the same time.
Doing the refactor first means the future plugin project becomes "implement a
host for existing registries" instead of "restructure the app under time
pressure." The cost of the seams alone is small (each is one step above the
code it replaces); the cost of discovering them mid-plugin-project is not.

## 9. The future this keeps open (out of scope, one paragraph)

With §2's rules honored, a future WASM host implements the *same registries*:
a plugin's registration records arrive over the host boundary in place of
built-in `register()` calls; hook subscribers become exported functions
invoked with serialized event records; capability scopes map to host-provided
module imports. Nothing in this refactor builds, names, or versions any of
that — it only ensures the seams are narrow, data-oriented, capability-scoped,
host-dispatched, and error-contained, which is the shape any sandboxed host
needs anyway.

## 10. Open questions

1. ~~Event-bus migration depth~~ — resolved by deferral (§4.2, owner
   decision 2026-08-29).
2. ~~Node-kind registry now or later~~ — resolved by survey: the registry
   already exists in attractor (`NodeHandlerRegistry`,
   `packages/attractor/lib/src/node_handler.dart:52`); step 2 hardens and
   uniformly routes tina's handler registrations through it, adding no kinds.
3. **Panel host scope:** migrate only the run panel (default) or also the
   transcript/chat panels? (Default: run panel only.)

## 11. Approvals — what plugins may and may not do (decided)

Tina has two approval mechanisms, and they sit on opposite sides of the
core/plugin boundary. The full contrast lives in
[Plan approval](../features/plan_approval.md) and
[ARCHITECTURE.md](../../ARCHITECTURE.md); this section records the rule for
plugins and uses plan approval as the worked example.

**Tool approval is core.** The permission decision (`PermissionPolicy.check`,
the asker chain in `packages/tina_engine/lib/src/permissions/`) has no plugin
descriptor and is wired by hand at the composition root. A plugin touches it
only through one narrow, presentation-level seam: it may supply a
`Renderer<ApprovalCard>` (`lib/tui/approval_card.dart:6-7`) — and the rule
stated there binds every plugin: *"choices and their responses remain owned
by the permission prompt."* A plugin may draw the card. It may not change the
question, the answer, or who answers.

**Plan approval is a plugin — but not purely.** `tina.plan`
(`lib/composition/plan_ui.dart`) provides the `PlanStore` service, the status
strip, and the `/plan` command; core `buildAgent` mints the agent-facing
pieces (the `update_plan` tool, the request middleware) per conversation from
the plugin's store (`agent_composition.dart:198-220`), because a shared
scope cannot tell which conversation a turn belongs to. Note what the tool
does *not* travel: `update_plan` implements `LocalControlTool`, so the
executor allows it without a permission ask
(`tool_executor.dart:445-447`). The plan gate never reaches the permission
path itself.

**The decided boundary:** plan approval stays a plugin. Core owns the
permission decision — a plugin must never re-derive policy: no plugin
decides who answers an approval, what the answers mean, or what happens when
nobody can answer. The intended shape is one narrow read-only door from a
plugin into the decision: *"may I ask? and can anyone answer?"* The plugin
asks; core decides. **That door does not exist yet** — and PR #61 (merged in
v0.8.30 as `0a5ace6`) shows the cost of its absence: answering "can anyone
answer" by re-deriving the posture inside the plugin's own tool and
middleware (`PlanTool.resolveApprovalMode`,
`packages/tina_app/lib/src/plans/plan_plugin.dart:142-149`) — exactly the
plugin-side policy re-derivation this boundary rules out, however practical
the stall it fixed. The correction — a `PlanPosture` value minted by core,
later generalised into a read-only scope key — is proposed in
[the posture-door proposal](plugin_posture_door.md).

---

## 12. Survey appendix — verified anchors

- Command dispatch switch: `lib/session_commands/session_command_handlers.dart:64`
  (context seam at `lib/session_commands/command_context.dart:44-49`).
- Provider registration typedefs: `packages/tina_engine/lib/src/llm/registry.dart:97,104`.
- Workflow pipeline module: `lib/pipeline/` (`pipeline_runner.dart:33`,
  `workflow_names.dart`, `default_workflow.dart`, `launch_workflow_tool.dart`);
  DOT nodes carry `system_prompt` + optional `llm_model`/`llm_provider` since #33.
- Panel abstraction: `packages/tina_console/lib/src/panel.dart:24`
  (`abstract class Panel extends Region implements Focusable`); run-panel
  plumbing at `lib/tui_coordinator.dart:1311-1420`.
- Host abstraction: `packages/tina_engine/lib/src/host/host_interface.dart:31`.
- Import boundary: `test/import_boundary_test.dart` (engine must not import
  TUI packages; `tina_console` and `tina_engine` are siblings).
- Composition root: `lib/composition/app_composition.dart` (config, registry,
  policy, session store, pipeline, scheduler, spend ledger, pause gate).
- Related prior proposals: `docs/proposals/app_composition_provider.md`,
  `docs/proposals/node_handoff_design.md`,
  `docs/features/terminal_panel_plan.md`.
