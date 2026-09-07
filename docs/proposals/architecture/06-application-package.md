# A06 — Extract the frontend-independent application package

Status: proposed; perform after A01–A05 and dependency enforcement from A07.

## Rationale

The engine package represents coding-agent capabilities. Application-specific
session operations, workflow integration and project services currently live
beside the TUI in root `lib/`. A `tina_app` package would give those services an
independent dependency declaration and test suite without terminal native assets.

Do not use package creation to postpone responsibility separation. A01–A05 must
first remove global construction, terminal configuration and service-to-composition
cycles. Keep the extraction itself predominantly mechanical.

## Scope and destination map

The paths below refer to current sources; earlier specifications may reorganize
them before this move. Split mixed files by responsibility rather than move the
entire directory blindly.

| Current responsibility | Destination |
| --- | --- |
| Conversation/session state, manager and application operations | `tina_app/lib/src/session/` |
| Turn executor and background supervision | `tina_app/lib/src/execution/` |
| Runtime configuration and neutral environment contract | `tina_app/lib/src/config/`, `src/platform/` |
| Session restoration and application persistence coordination | `tina_app/lib/src/persistence/` |
| Summary/environment services and project adapters | `tina_app/lib/src/summaries/`, `src/environment/` |
| DOT workflow execution adapter, supervisor, run store and catalog | `tina_app/lib/src/workflows/` |
| Neutral region allocation and application tool integrations | `tina_app/lib/src/regions/` |
| Agent assembly using explicit runtime factories | `tina_app/lib/src/composition/` |
| CLI parsing, startup exit dispatch, TOML/theme presentation mapping | Root `lib/` and `bin/` |
| TUI coordinator, panels, overlays, attention queue, terminal geometry | Root `lib/tui/`, frontend host modules |
| Tmux UI/exit handling, update/install actions | Root platform/CLI adapters |

`workflow_permission_asker.dart`, interviewers, commands and project setup files
need individual classification. Their neutral policies can move; attention
queues, overlays and terminal rendering cannot. Root-only commands register
alongside application commands using A04's narrow contracts.

## Dependency contract

`tina_app` may depend on `tina_engine`, `attractor` and neutral utilities it uses.
Add `tina_index` or `fuzzy_ranker` only for actual direct use. It must not depend
on `tina`, `tina_console`, `dart_notcurses`, terminal adapters or root config.
The engine must not depend on `tina_app` or `attractor` merely to accommodate
application workflows; their integration belongs in `tina_app`.

Filesystem/process adapters may remain in `tina_app`. Frontend-independent means
independent of terminal interaction, not free of all I/O. Isolate those adapters
behind the service contracts so most application tests can use memory fakes.

## Public surface

Create `lib/tina_app.dart` exporting the operations, request/result values,
configuration and interfaces needed by the root. Keep implementation helpers in
`lib/src/`. Add focused entry libraries only when they provide a real dependency
or readability benefit; do not export every file by default.

Root code must not import `package:tina_app/src/...`. Cross-package test helpers
must not be imported from another package's `test/` tree. Keep local fakes local;
extract a deliberately supported testing library only when substantial shared
behavior justifies it.

Preserve existing persisted data and identifiers. This is a private path package
with `publish_to: none`; there is no public release API or independent publication
workflow implied by extraction. Choose an SDK constraint compatible with actual
language features and current project requirements.

## Composition and lifecycle

Root startup owns platform discovery, file/config loading and user interaction.
It supplies resolved settings and external resources to application composition.
Application services must not call the final composition root. Package-internal
assembly may construct reusable operations from supplied factories but cannot
initialize a terminal, parse argv or change process cwd.

Provider/store ownership remains as specified in A01. Moving files must not
change who closes a catalog, conversation provider or session store.

## Migration procedure

1. Run A07 against the proposed source set and remove remaining forbidden paths.
2. Create the package manifest, export library and analysis configuration.
3. Move neutral values/contracts first, then state/operations, then service
   implementations and adapters. Update relative imports with each group.
4. Move corresponding tests and helpers; leave CLI/TUI integration tests at root.
5. Update root path dependencies and remove dependencies no longer directly used.
6. Update CI and release build scripts that enumerate package resolution paths.
   Inspect release workflows for assumptions; do not alter release behavior.
7. Remove transitional root re-export shims once repository callers migrate.
8. Update architectural rules and documentation to the actual final paths.

## Validation and acceptance

- From the package directory, dependency resolution, analysis and tests work on
  a runner without notcurses system packages or native terminal initialization.
- The resolved application dependency graph contains no terminal packages.
- Application operation/service tests moved to the package still test the same
  behavior; root retains end-to-end frontend composition coverage.
- Root CLI prompt/workflow paths and TUI startup/resume integration checks pass.
- Root and package imports use public entry points with no dependency cycle.
- No persisted data migration, flag change or command change is introduced.
- A08 includes the new package explicitly before the extraction merges.

## Stop conditions

If the proposed package requires root imports, a giant callback bag, or terminal
types in public signatures, return to the relevant earlier specification. Do not
resolve a cycle using cross-package relative paths or public exports of internals.
