# CI coverage and runtime

Regular CI selects changed owned packages and their transitive consumers from
actual `pubspec.yaml` dependencies, dev dependencies and overrides. Root
analysis/tests still check cross-package architecture rules for every code
change. Known documentation paths skip tests; Markdown fixtures do not.
Version-only root manifest bumps select the root without forcing unrelated
packages. Shared build/CI configuration, native submodule changes, unknown paths
and unavailable base revisions select everything. Weekly and manual runs also
select everything. Existing per-package jobs retain their native/pure-Dart
environments and names. Superseded runs are cancelled within the same event/ref.

The root job resolves owned packages four at a time; this is needed for the
analyzer and architecture graph even when only some package tests are selected.
Native interactive checks run when the affected graph reaches the frontend or
root executable sources. Tools sandbox checks stay platform-specific.

## Release smoke review

The v0.9.49 macOS job built in 42 seconds, then spent 10m44s in seven sequential
smoke suites. The release job now runs up to three suites concurrently, with
separate processes, ephemeral HTTP ports, temp stores and PTYs. Every suite
still runs on every shipped platform and any failure prevents publication.
Per-suite logs are uploaded even after failures. Signing, notarization,
checksums, manifest signatures and installed-layout verification remain gates.

| Suite | Why keep it beyond unit tests? |
| --- | --- |
| Engine | Actual executable wiring: turns, approvals, networking, MCP, persistence, cancellation and clean exit. |
| Native images | Native asset loading, decoded image painting, input/resize/scroll and terminal teardown. |
| Classification | Live classifier hierarchy, focus and rendering on both terminal backends. |
| Panels | Popup damage/restoration, settings frames, approval memory, alerts and panel controls. |
| Backends | Default native selection, forced ANSI, unsupported-terminal fallback/failure and resumed input. |
| Shell | Immediate shell dispatch, output/exit status and cancellation with and without split panels. |
| Process output | Flooding output and direct TTY writes cannot corrupt the UI; pipelines, background jobs and MCP stay isolated. |

The expensive engine suite repeated all non-layout checks at three geometries.
CI uses `--quick` to run the **complete scenario** once at 80x24; CLI checks and
request-accounting assertions are retained. Dedicated native-image,
classification and popup suites still exercise small/large geometries, and
engine resize checks still run. Full three-geometry engine coverage remains the
script default for targeted debugging. This trades repeated engine behavior at
size edges for faster releases, while retaining separate layout coverage.

External-output injection in the process-output fixture uses a separate
nonblocking PTY descriptor and a bounded wait while draining pending paints.
This prevents the test harness itself deadlocking on macOS when the output
queue is full; the corruption/restoration assertions are unchanged.

Validation on the published v0.9.50 macOS binary: all seven suites passed in
about 95 seconds with three workers (their individual runtimes totalled about
255 seconds). This is a local measurement, not a hosted-runner benchmark.

Local checks:

```sh
dart test test/architecture/ci_selection_test.dart test/architecture/ci_owned_packages_guard_test.dart
python3 -m unittest discover -s tool/ci -p 'test_*.py'
actionlint .github/workflows/ci.yml .github/workflows/release.yml
python3 tool/ci/run_release_smokes.py --binary /path/to/bundle/bin/tina
```
