# Tickets

All tickets live in this directory — nothing under `docs/`. One file per
ticket, named `<id>.md` where `<id>` is the short random slug (`tin-xxxx`)
used in commit subjects and cross-references.

## Frontmatter

```yaml
---
id: tin-xxxx
status: open        # open | closed
deps: []            # ids of tickets that must close before this one
links: []            # related tickets (non-blocking)
created: <ISO-8601>
type: bug           # bug | feature | chore | proposal
priority: 1          # 1 highest .. 3 lowest
assignee: Nick Fisher
tags: [tui, keys]
---
```

Body sections as needed: `# Title`, `## Context`, `## Repro` (bugs) or
`## Proposal` (features), `## Acceptance`.

## Working rules

- A ticket is filed the moment a problem is noticed, with repro notes —
  not when work on it starts.
- `deps` is the blocking relationship: a ticket with open deps is not
  pickable, even if it's higher priority.
- A ticket closes only when a regression test exists, the root suite and
  the touched package's suite are green, and the original repro passes
  from a clean restart. Close = commit, in the same commit as the fix
  when practical.
- `docs/STATUS.md`-style sweep state lives at `STATUS.md` in this
  directory and is rewritten (never appended) at every checkpoint.
