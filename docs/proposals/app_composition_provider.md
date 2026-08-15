# AppComposition.provider — is the startup provider in the wrong place?

**Ticket:** tin-9zqx
**Status:** Proposal only — no code or test changes.
**Date:** 2026-08-15
**Author:** Nick Fisher

This document analyzes one field: `AppComposition.provider` (the startup
`LlmProvider`). It gives restructure options, rename options, effort, and a
recommendation. Every claim is checked against the code. File and line numbers
point at the current branch (`asb/app-provider-simplify`).

---

## 1. What the field is today

`AppComposition` (lib/composition/app_composition.dart:15-62) holds the
process-wide parts shared by every frontend: config, environment, provider
registry, startup provider, policy, session store, pipeline, scheduler, spend
ledger, pause gate, and the resolved initial session ids/history/manifest
(lib/composition/app_composition.dart:16-44).

The startup provider is built inside `buildAppComposition`
(lib/composition/app_composition.dart:92-100) from `config.provider` /
`config.model`, with the CLI key, base URL, and timeouts as overrides. It is
stored as `AppComposition.provider` (lib/composition/app_composition.dart:19,
:138).

The build order matters: the spend ledger and pause gate are created first, and
the registry decorator is set to `MeteringProvider` BEFORE the provider is
built (lib/composition/app_composition.dart:85-91). So every provider built
through the registry after that point is metered. The registry applies the
decorator inside `build` (packages/tina_engine/lib/src/llm/registry.dart:328).
This ordering does not depend on the provider living in the composition. It
only depends on the decorator being set before the first `registry.build` call.
Any option that builds the provider after `buildAppComposition` ran keeps the
same guarantee.

## 2. Who uses it (verified)

Three consumer groups read `app.provider`:

1. **Headless `--prompt`.** `buildAgent(provider: app.provider)` at
   bin/tina.dart:349. Closed at bin/tina.dart:389.
2. **Summary fleet.** `SummaryRunner.run` builds its own ephemeral composition
   (lib/summaries/summary_runner.dart:126-130) and uses `app.provider` at
   lib/summaries/summary_runner.dart:147, closing it at :165.
3. **The TUI — this contradicts the ticket.** The ticket says the TUI path
   "never reads app.provider". That is wrong. `TuiCoordinator.create` reads it
   at lib/tui_coordinator.dart:247 and uses it for:
   - the initial conversation's metadata (lib/tui_coordinator.dart:487),
   - the initial agent (lib/tui_coordinator.dart:506),
   - the initial `Conversation` object (lib/tui_coordinator.dart:520),
   - the restore fallback provider when a restored conversation has no stored
     model ref or an unknown one (lib/tui_coordinator.dart:585 →
     lib/persistence/session_restore.dart:111, :117).

   So the TUI is a third consumer, not a non-consumer. But the ticket's spirit
   holds: only the FIRST conversation gets the startup provider. Every later
   conversation builds its own through `providerFactory`
   (lib/tui_coordinator.dart:296-307) and `SessionManager._buildConversation`
   (lib/session_manager.dart:246).

**Two paths build a provider and never use it.** The headless `--workflow`
path (bin/tina.dart:280-307) and the headless `/index` path
(bin/tina.dart:316-336) close `app.provider` (bin/tina.dart:303 and :332)
without reading it. The workflow path runs node agents through the scheduler,
which builds providers from the registry
(lib/composition/app_composition.dart:120-125). The `/index` path runs the
fleet through `SummaryRunner`, which builds its own provider anyway
(lib/summaries/summary_runner.dart:126-130). So on those two paths the startup
provider is constructed and closed for nothing. This is real waste the field
causes today.

## 3. Lifecycle models (verified)

- **TUI:** the initial `Conversation` owns the provider. It is closed when the
  conversation closes — via `/model` swaps (lib/conversation.dart:25-29) or
  teardown (`SessionManager.closeAll` → `close()` on every conversation,
  lib/tui_coordinator.dart:2044 → lib/session_manager.dart:400-404).
- **Headless:** the entry point closes `app.provider` directly
  (bin/tina.dart:303, :332, :389).
- **Summary fleet:** closes its own ephemeral composition's provider
  (lib/summaries/summary_runner.dart:165).

So there are three close paths, not two. They agree only by convention.

**A shared-instance hazard exists today.** On resume, a restored conversation
with no stored model ref falls back to the startup provider instance
(lib/persistence/session_restore.dart:111, :117). That is the same instance the
initial conversation holds. `closeAll` then closes it once per conversation
that holds it (lib/session_manager.dart:403). Concrete providers close their
HTTP client (packages/tina_engine/lib/src/llm/anthropic.dart:36,
openai_compatible.dart:52, gemini.dart:43). A double close may throw during
teardown. Any option below that makes ownership local removes this hazard.

## 4. Why the field exists (the defense, verified)

- Tests inject a fake through the `provider:` parameter
  (lib/composition/app_composition.dart:76); see test/tui_coordinator_test.dart:54-58
  and ~20 more call sites in that file.
- The headless path has no conversation manager, so it needs a provider handed
  to it (bin/tina.dart:349).
- The class doc says its job is to stop the two entry points drifting on
  provider/policy/store wiring (lib/composition/app_composition.dart:9-14).

## 5. Restructure options

### Option A — Keep the field, rename it, document it

**What changes.** Rename `AppComposition.provider` to `startupProvider`.
Update the class doc to say plainly: this is the first conversation's provider;
the TUI's initial conversation owns it, headless closes it, the fleet's copy is
ephemeral. No behavior change. Roughly 10 read sites
(bin/tina.dart:303, :332, :349, :389; lib/tui_coordinator.dart:247;
lib/summaries/summary_runner.dart:147, :165) plus the field itself
(lib/composition/app_composition.dart:19, :50, :92, :138).

**What breaks.** Nothing. Compile-level rename only.

**Effort.** XS (under an hour).

**Assessment.** Honest but weak. The name stops lying, but the scope mismatch
stays, the two build-without-use paths stay, and the double-close hazard stays.

### Option B — Move construction to the entry points

**What changes.** `buildAppComposition` stops building a provider. The field
and the `provider:` test parameter go away. Each entry point builds its own:

- bin/tina.dart headless: build via `app.registry.build(...)` before `buildAgent`.
- `TuiCoordinator.create`: build the initial conversation's provider itself. It
  already has the recipe — `providerFactory` (lib/tui_coordinator.dart:296-307)
  builds the same thing with the same overrides.
- `SummaryRunner`: builds its own already (lib/summaries/summary_runner.dart:126-130);
  it just stops going through the field.

**What breaks.**
- The `--workflow` and `/index` headless paths no longer get a provider at all —
  that fixes the waste in §2, not a regression.
- Test injection moves: tests pass a fake provider to `TuiCoordinator.create`
  (or a factory) instead of `buildAppComposition`
  (test/tui_coordinator_test.dart:54-58 and the rest of that file).
- The registry decorator ordering holds — entry points run after
  `buildAppComposition` returned, so `registry.build` is metered either way
  (lib/composition/app_composition.dart:90-91).
- The class doc's no-drift promise (lib/composition/app_composition.dart:12-14)
  weakens: the provider recipe now lives in two places (bin/tina.dart and
  tui_coordinator.dart). Policy and store wiring stay shared, so the drift risk
  is limited to provider arguments.

**Effort.** M (half a day including test churn across
test/tui_coordinator_test.dart).

**Assessment.** Clean scope, but it re-opens a small drift window the
composition was created to close.

### Option C — A "resolved initial conversation" object that owns the provider

**What changes.** Introduce one object, e.g. `InitialConversation`, holding
`provider`, `conversationId`, `history`, and `manifest`. Build it inside
`buildAppComposition`. `AppComposition` drops `provider` and the four
`initial*` fields (lib/composition/app_composition.dart:38-44) and gains one
`initial` field. Consumers read `app.initial.provider`.

**What breaks.** Every consumer of `app.provider` AND every consumer of the
`initial*` fields (bin/tina.dart:216-222, :348, :356-364, :383-385;
lib/tui_coordinator.dart:470-472, :563). Tests unchanged in shape (they still
pass `provider:` into `buildAppComposition`).

**Effort.** M (half a day).

**Assessment.** The grouping itself is good — the four `initial*` fields are
already a cluster. But it does not fix the core issues: the provider is still
built eagerly for paths that never use it, the TUI still copies it into a
`Conversation` that then owns it, and the fleet still gets a fresh provider via
a fresh composition. It is a rename with extra steps.

### Option D — Build on demand: a factory method on the composition

**What changes.** Drop the `provider` field. Add one method:

```dart
LlmProvider buildStartupProvider() => registry.build(
    '${config.provider}/${config.model}',
    apiKeyOverride: config.apiKey,
    baseUrlOverride: config.baseUrl,
    ...);
```

The recipe (lib/composition/app_composition.dart:92-100) moves into this method
unchanged. `buildAppComposition` keeps the optional `provider:` parameter; when
set, the method returns the injected instance, so tests keep working as-is
(lib/composition/app_composition.dart:76).

Consumers:
- bin/tina.dart headless `--prompt`: `provider: app.buildStartupProvider()` at
  :349, close at :389 — unchanged shape.
- Headless `--workflow` and `/index`: call nothing. No provider is built. The
  waste in §2 disappears.
- `TuiCoordinator.create`: `final provider = app.buildStartupProvider();`
  (replaces lib/tui_coordinator.dart:247). Same ownership as today.
- `SummaryRunner`: calls it on its own ephemeral composition (replaces
  lib/summaries/summary_runner.dart:147).

**What breaks.**
- Compile-level churn at the same ~10 sites as Option A, plus the field removal.
- Any code that expected exactly one provider per run. Nothing does — each path
  already closes what it uses (§3).
- The metering guarantee holds: the decorator is set before the method can be
  called, because the method lives on the built composition
  (lib/composition/app_composition.dart:90-91).

**Effort.** S to M (a few hours; the method is a move, not a rewrite).

**Assessment.** Keeps the no-drift promise (one recipe, one place). Makes
lifetime explicit and local. Removes the build-without-use waste. Keeps the
test seam. Does not fix the restore double-close hazard by itself — that needs
the restore fallback to build its own provider instead of reusing the account
provider (a one-line change at lib/persistence/session_restore.dart:111 worth
doing under any option).

### Option E (considered, rejected) — Remove the field and pass a `ProviderFactory` everywhere

The TUI already threads a `providerFactory` closure
(lib/tui_coordinator.dart:296-307, lib/session_manager.dart:52). One could
remove the field and hand every consumer a factory. Rejected as a standalone
option: it is Option D with the method torn off the object, and it adds a
parameter to every signature for no gain. Listed for completeness.

## 6. Rename evaluation for `AppComposition`

Honest read, name by name:

| Name | Fit | Why |
|---|---|---|
| `AppComposition` (keep) | Good | Says what it is: the assembled shared parts. The doc comment defines its scope precisely (lib/composition/app_composition.dart:9-14). |
| `AppContext` | Weak | "Context" names a bag of anything. It drops the one useful fact — that this is assembled once, deliberately, in one function. Also collides with the many local `ctx` variables already in the code (lib/persistence/session_restore.dart:34, lib/session_commands/command_context.dart:105). |
| `AppBootstrap` | Poor | Names the build phase, not the product. It fits a function (`buildAppComposition` already is that function), not the class. |
| `SessionAssembly` / `SessionComposition` | Poor | Wrong scope: the parts are process-wide (registry, scheduler, quota), not per-session. Worse, "session" already means a persisted session here (`SessionStore`, `SessionManager`, `--resume`). The name would lie in both directions. |
| `RunAssembly` / `RuntimeAssembly` | Fair | "Run" matches the process lifetime. But it renames a class referenced in 8 files for zero behavior gain, and "Composition" is already established in this repo (`agent_composition.dart`, `buildAgent`). |

**Conclusion: keep `AppComposition`.** The class shape is fine once the
provider field is gone or renamed. Do rename the FIELD — `provider` reads as
"the app's provider" but means "the first conversation's provider". Under
Option D the field disappears and the method name `buildStartupProvider()`
carries the honest meaning. Under Option A, rename the field to
`startupProvider`.

## 7. Recommendation

**Adopt Option D** (factory method on the composition), and separately:

1. Fix the restore fallback to build a fresh provider instead of reusing the
   startup instance (lib/persistence/session_restore.dart:111) — removes the
   double-close hazard from §3.
2. Keep the class name `AppComposition`; rename the field/method to
   `startupProvider` / `buildStartupProvider` so the name states the real scope.
3. Update the class doc (lib/composition/app_composition.dart:9-14) to drop
   "the startup provider" from the list of session-long parts and say where the
   provider is built instead.

Why D over the others: it is the only option that fixes the scope mismatch
(§1), the build-without-use waste (§2), and the drift risk (§4) at the same
time, while keeping the test seam and the metering ordering intact. Option B
fixes scope but re-opens drift. Option C fixes naming but keeps eager builds.
Option A fixes nothing structural.

If the team wants zero churn now, Option A is a safe floor — but it should be
recorded as "deferred", not "resolved".
