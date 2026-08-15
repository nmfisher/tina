# Example workspace

A small, deliberately-shaped Dart monorepo to point tina at when you want a
realistic agent target without risking a real project. It is the default
workspace for manual testing and UI sweeps.

## Shape

Four packages of graded sizes with cross-cutting dependencies:

- `packages/core` — the domain model (events, `Result`, `Repository`, …).
  The largest package; most files live here.
- `packages/store` — in-memory and JSON-file repositories implementing
  core's interfaces, plus a query subpackage.
- `packages/reports` — small; summary reporting and CSV export over the
  store's query API.
- `packages/cli` — a `track` command-line app wiring core + store + reports
  together.

Dependency direction: `cli` → `reports`/`store` → `core`. `core` imports
nothing from the other packages.

## Deliberate edge cases

These exist on purpose — they exercise tool robustness (UTF-8 handling, the
Dart AST parser, git-aware completion, large-file reads). Do not "fix" them:

| Path | What it probes |
| --- | --- |
| `packages/core/lib/src/naive_cache.dart` | emoji/CJK content (filename was non-ASCII; its NFD form corrupted a dirent on the exFAT dev volume — NFD handling now lives in tina_index's walker tests) |
| `packages/core/lib/src/placeholder.dart` | empty file |
| `packages/core/lib/src/broken_probe.dart` | intentional syntax error (parser robustness) |
| `data/long_line.txt` | a single ~10 KB line |
| `assets/logo.png` | binary content |
| `assets/blob.bin` | invalid UTF-8 bytes |
| `packages/NOTICE` | symlink pointing at a missing file |
| `docs/decisions/` | prose files with wide-character content |

## Dirty git state

The workspace ships clean inside the tina repo. To create a deterministic
dirty state (one staged edit, one unstaged edit, one untracked file) for
testing git-aware behaviour, run from the repo root:

```sh
./tool/example_workspace.sh dirty
./tool/example_workspace.sh reset   # restore pristine state
```

`reset` restores state via git, so the workspace must be **committed** to
the tina repo first — the script refuses to reset otherwise.

## Analyzer

`analysis_options.yaml` here excludes this subtree from the analyzer — the
fixture packages are never `pub get`-ed, and `broken_probe.dart` must stay
broken. `tina_index` parses these files with its own parser and is unaffected.
