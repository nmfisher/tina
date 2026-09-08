# A07 — Enforce package and module dependency boundaries

Status: implemented (2026-09-08) with a 51-entry baseline; ratchet down during
A02–A06 migrations.

## Existing gap

[`test/import_boundary_test.dart`](../../../test/import_boundary_test.dart)
scans selected paths for direct console imports. It misses paths such as
`SessionController → SummaryIndex → Config → tina_console` and indirect imports
through test helpers. Its explicit guarded list also requires remembering to add
every new application directory.

The check is useful but currently proves a weaker property than its comments
describe. Replace that ambiguity with explicit graph rules and useful diagnostics.

## Rules

| Rule | Required property |
| --- | --- |
| Package direction | No reusable package imports root `tina`; no package cycle |
| Frontend exclusion | Engine and application code cannot reach terminal packages, directly or transitively |
| Assembly direction | Application services cannot import final composition modules |
| Public APIs | Cross-package imports use public libraries, never another package's `src/` |
| Test isolation | Application unit tests and their helpers cannot reach terminal packages |
| Coverage | Newly added files are classified by directory defaults, not silently omitted |

Before A06, application classification covers the migrated module directories in
root `lib/`. After A06, the package manifest supplies the strongest boundary and
the graph check continues to police source-level direction and public imports.
Root composition and frontend integration tests are explicitly allowed to reach
both application and terminal packages.

## Implementation design

Build a small repository checker with an import graph and a declarative policy.
Keep it available as an architecture test or a script invoked by a test/CI step.
Do not rely on matching one physical line of source text.

Use Dart's parser to read `import`, `export`, `part`, and library relationships.
If using `analyzer`, declare it directly as a development dependency; do not rely
on `tina_index` providing it transitively. Parse directives without resolving the
entire program unless resolution is needed for correctness.

### Graph construction

1. Enumerate owned Dart source and test/helper files plus package manifests.
2. Resolve relative URIs and local `package:` URIs using package roots/package
   configuration. Normalize paths and reject escapes that hide cross-package use.
3. Add edges for imports, exports and parts. Treat parts as belonging to their
   library; avoid false package cycles from the bidirectional library relation.
4. Include all conditional import/export alternatives. An inactive platform
   branch must not hide a forbidden frontend dependency.
5. Classify SDK URIs as terminal-free leaves. Use resolved package metadata for
   external packages and dependency closure where required.
6. Traverse reachable imports from guarded modules/tests and report violations.
   Check manifest dependency closure separately for package-level isolation.

Declared package dependencies and source imports answer different questions.
A package with an unused terminal dependency can still incur unwanted build
requirements; reject it in the application manifest even when no import uses it.
Development dependencies are not production closure edges, but test checks must
include dependencies actually used by tests and helpers.

## Diagnostics and exceptions

Report the rule, originating file, offending directive location and shortest
dependency path, for example:

```text
frontend-exclusion:
  lib/session_controller.dart
  -> lib/summaries/summary_index.dart
  -> lib/config.dart
  -> package:tina_console/tina_console.dart
```

Record existing violations in a checked-in baseline with an exact edge/path,
reason and owning specification. Do not allow broad wildcard exemptions such as
all of `lib/` or all tests. The checker fails on new violations and stale baseline
entries, making removal part of the migration. Missing classified directories or
unresolved local URIs must fail clearly rather than count as no dependencies.

Current `src/` access from the TUI to the notcurses backend needs an explicit
migration exception until a suitable public console factory/capability exists.
Use that exception to track the work; do not re-export the entire backend merely
to satisfy a string check.

## Migration

1. Implement parser/resolver and graph fixtures independent of repository policy.
2. Run against the current tree and review findings before creating the baseline.
3. Preserve existing direct-import checks until the graph checker subsumes them.
4. Apply module defaults to migrated application directories from A02–A05.
5. Remove baseline entries in the PRs that fix their dependencies.
6. Add `tina_app` manifest closure enforcement with A06; classify its whole source
   tree and unit-test helper closure by default.

## Tests and acceptance

- Fixtures catch direct, multi-hop, export-mediated, relative-path and conditional
  violations, plus forbidden dependencies imported through helpers.
- Fixtures accept legitimate root composition and frontend integration tests.
- Package cycles and imports of another package's `src/` report actionable paths.
- Missing paths, malformed/unresolved local directives and stale exceptions fail.
- Adding a new application file automatically subjects it to the rules.
- Check execution requires no terminal initialization or network source lookup.
- Final A06 state has no exception permitting application-to-terminal reachability.

## Limits

Static imports do not describe arbitrary runtime loading or process execution.
Do not claim this checker proves runtime purity. Review dynamic loading separately
if introduced. The checker enforces architectural dependency rules, not behavior.
