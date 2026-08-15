# Tracker architecture

The workspace is an event-sourced task tracker split across four packages:

```
cli ──▶ reports ──▶ store ──▶ core
 └───────────────────┘
```

- **core** owns the vocabulary: `TaskEvent` and its subclasses, `EventBus`,
  `Result`, `Repository`, `NaiveCache`. It has no dependencies.
- **store** implements `Repository` twice — in memory (reference) and over a
  JSONL file (durable) — and adds the `query/` subpackage (`Filter`,
  `comparatorBy`) plus `Migration`/`runMigrations` for schema evolution.
- **reports** folds an event stream into a `TaskSummary` (open/completed
  counts) and exports CSV.
- **cli** is a thin argv dispatcher over the three: `track add`, `track
  list`, `track report`.

## Invariants

1. Dependency arrows point only leftward in the diagram above; `core`
   imports nothing from siblings.
2. Failures travel as `Result` values, not exceptions. `FileSystemException`
   and `FormatException` are caught at the store boundary and converted.
3. The event log is append-mostly; deletes rewrite the file atomically via
   a `.tmp` rename.

## Known sharp edges

- `JsonFileStore` is single-writer only.
- `EventBus.publish` is synchronous; slow subscribers stall the caller.
- `NaiveCache` is unbounded — see ADR 0002 before relying on it.
