# Session persistence as a plugin — phase specifications

Status: proposed; implementation has not started.
Umbrella design and assumption audit: [`../session_persistence_plugin.md`](../session_persistence_plugin.md).
Date: 2026-09-22.

These specifications split the session-persistence plugin migration into
independently landable changes. Each phase lands green on its own; nothing is
feature-flagged. Proposed type names and signatures are illustrative, not
existing APIs.

## Shared context

Today `bin/tina.dart:193` constructs `JsonlSessionStore.defaultLocation()`
inline and passes it to `buildAppComposition(store: ..., ownsStore: true)`.
`AppComposition.store` is the field every downstream consumer reads
(`SessionController`, session commands, attach/detach). Startup also touches
the store **before** the plugin runtime activates: the resume picker,
`resumeCwdFor` / `_restoreSessionCwd`, and `--list` (`bin/tina.dart:804`).
Advisory locking type-checks for Jsonl specifically (`bin/tina.dart:362`).
The plugin runtime itself (`PluginDescriptor`, `PluginContext`, `PluginScope`,
`ServiceKey`) exists in `packages/tina_engine/lib/src/runtime/` and is proven
by `tools/workspace_tool_plugins.dart`.

## Specifications

| ID | Specification | Principal result | Prerequisites |
| --- | --- | --- | --- |
| SP1 | [Service key + JSONL plugin](01-service-key-and-jsonl-plugin.md) | The active store resolves through plugin scope; JSONL is a registered plugin | None |
| SP2 | [Session index for startup](02-session-index.md) | Pre-runtime startup reads go through a narrow `SessionIndex` | SP1 |
| SP3 | [Provider selection config](03-provider-selection.md) | `[sessions]` selects the backend; unknown ids fail at startup — **implemented** | SP1; benefits from SP2 |
| SP4 | [Lockable store capability](04-lockable-store.md) | Locking decided by capability, not a Jsonl type test | SP1 |
| SP5 | [Example backend + docs](05-example-backend-and-docs.md) | A non-file backend passes the persistence contract suite; docs updated | SP1–SP4 for docs; SP1 only for the backend |

## Delivery sequence

1. SP1 first — it defines the resolution mechanism everything else uses.
2. SP2 and SP4 are independent of each other; land in either order.
3. SP3 once SP2 exists so `resolveSessionIndex` and the plugin list agree on
   one config read.
4. SP5 last; its contract suite is the regression net for the whole program.

## Cross-program note

Cloud backends need async construction; `PluginFactory.build` is synchronous.
That gap belongs to the plugin runtime program
(`docs/proposals/plugin_runtime.md`), not this one. The in-memory example
backend in SP5 is synchronous and unaffected.
