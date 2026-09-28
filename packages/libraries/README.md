# Reusable libraries

These packages expose APIs that applications and plugins can use independently
of the agent loop. Each retains its own package name, public API and tests.

| Package | Responsibility |
| --- | --- |
| `file_tree` | File inventories, tree hashes and change detection |
| `fuzzy_ranker` | Fuzzy matching, ranking and completion-provider contracts |
| `attractor` | DOT workflow graphs and execution |
| `classifier` | Structured judgments, classification and repository exploration |

Agent plugin implementations live in `packages/plugins/`. The runtime and
frontend packages remain directly under `packages/`.

Attractor is retained for the workflow plugin and the legacy app. Moving it
here does not connect workflows to the new app; the architecture policy still
enforces that boundary.
