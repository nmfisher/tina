# A08 — Give every owned package explicit CI coverage

Status: proposed; independent of the production refactors.

## Problem

The current [CI workflow](../../../.github/workflows/ci.yml) explicitly analyzes
and tests root `tina`, `tina_engine`, `tina_console` and `tina_index`. `attractor`
and `fuzzy_ranker` have their own tests but no corresponding explicit test job.
Root analysis of nested files is not a substitute for running each package's
test directory in its own dependency context.

## Desired coverage

| Package | Analyze and test | Native terminal dependencies | Notes |
| --- | --- | --- | --- |
| Root `tina` | Yes | Yes, for frontend integration coverage | Git adapter tests need isolated identity |
| `tina_engine` | Yes | No | Preserve existing platform-specific test behavior |
| `tina_console` | Yes | Yes | Preserve native and fake-backend coverage |
| `tina_index` | Yes | No | Analyzer dependency resolves in package context |
| `attractor` | Yes | No | Run engine, parser, rendering and handler suites |
| `fuzzy_ranker` | Yes | No | Small independent unit suite |
| `tina_app` after A06 | Yes | No | Application tests must remain terminal-independent |

`dart_notcurses` is a separately maintained submodule. Preserve its existing
integration/build coverage and document that policy explicitly. Adding its full
standalone upstream suite is a separate decision, not an implied requirement for
this change. Examples are fixtures rather than production package jobs unless
the repository already gives them a separate validation contract.

## Workflow design

Prefer a matrix for terminal-free owned packages if it reduces duplication
without changing check semantics. Keep root and console jobs separate where they
need native link dependencies. Use stable, identifiable job names, and preserve
existing required-check names where possible; changing branch-protection settings
is not part of this specification.

Each package job checks out necessary sources, installs the repository-supported
Dart SDK, resolves dependencies in that package directory, runs `dart analyze`
there, and runs `dart test` there. Do not add a formatting gate: existing CI
deliberately does not require formatting, and this task does not change that policy.

Root analysis currently traverses nested package tests. Until that changes
deliberately, resolve every owned nested package's development dependencies before
root analysis, including `attractor` and `fuzzy_ranker`. Alternatively adopt a
clearly scoped root analysis configuration in the same PR and verify no source
loses coverage. Do not silently exclude nested source to hide missing packages.

### Isolation and environment

Terminal-free jobs must not install notcurses linker packages. This makes the
absence of a terminal dependency observable, especially for the future app job.
Git integration tests should set identity within their temporary repositories
where practical. If a job-level identity remains necessary, confine it to that
ephemeral runner and document the reason.

Retain current live-provider test opt-in/skip behavior. Routine CI must not gain
new external API credentials or become dependent on provider availability.
This specification does not redesign those tests.

## Package inventory guard

Maintain one explicit list of owned package paths used by CI or by a small
consistency check. Compare `packages/*/pubspec.yaml` against this list plus a
documented submodule exclusion. A newly added package must either gain a job or
an explicit reviewed exclusion; it must not silently inherit root-only coverage.

Choose the simplest implementation: a matrix plus a consistency script is enough.
Do not add dynamic untrusted workflow generation or a general build orchestrator.
Cache configuration, if retained, must account for each package's dependency
files rather than reuse a root-only dependency key blindly.

## Migration steps

1. Add `attractor` and `fuzzy_ranker` analysis/test jobs or matrix entries.
2. Update root dependency preparation for their test-only imports.
3. Add the owned-package inventory check with the native submodule exception.
4. Run the new package commands locally where available and inspect CI results.
5. Add `tina_app` to the inventory, resolution preparation and jobs in A06's PR.

## Validation and acceptance criteria

- Workflow syntax is valid and every owned package has an explicit test command
  executed with its own package directory as the working directory.
- New package jobs pass analysis and tests with no native terminal installation.
- Root and console retain their current native setup and integration coverage.
- Existing check names remain stable or the PR explicitly documents required
  repository-setting follow-up; no assumption of automatic branch-rule updates.
- The inventory check fails on an unclassified new package manifest.
- Root analysis resolves all nested development dependencies or intentionally
  delegates those sources to independently enforced package analysis.
- No release workflow, publication, secrets or test-formatting policy changes.

## Failure handling

If newly executed suites reveal existing failures, report and fix them in scoped
changes before claiming complete coverage. Do not mark jobs optional or exclude
failing tests merely to make the workflow green. Platform-specific skips remain
acceptable only when they express the actual platform contract.
