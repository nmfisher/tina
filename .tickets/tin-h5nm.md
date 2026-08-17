---
id: tin-h5nm
status: closed
deps: []
links: [tin-h8uw]
created: 2026-08-17T05:58:00Z
type: bug
priority: 2
assignee: Nick Fisher
tags: [environment-agent, ceremony, status]
---
# Environment ceremony reports success without verifying ENVIRONMENT.md was written

## Context

`EnvironmentRunner.run()` (lib/environment/environment_runner.dart:121-129)
returns true when the agent's history ends on a non-empty assistant **text**
turn (`_finished`), then calls `store.record()` — pinning the region fresh —
and the coordinator tells the user
`Environment record updated (ENVIRONMENT.md).` (session_controller.dart:236).

Nothing checks that `ENVIRONMENT.md` was actually created or modified. An
agent that answers in prose without ever invoking its write tool produces a
false success. Verified with the stub provider (its canned turn is plain
text, no tool calls): 3/3 ceremonies printed "Environment record updated"
while `ENVIRONMENT.md` did not exist anywhere (only
`examples/workspace/.tina/environment/tracking.json` was written, stamped
fresh).

Real-provider shape: any model reply that finishes text-first without
writing the record → user told the record is updated, region marked fresh,
and because the record is still absent the first-load path re-runs the
whole ceremony (a provider round-trip) on every launch — each time
claiming success.

## Repro (deterministic, stub)

1. Stub server, scenario `normal`; fresh `HOME` with the stub config.
2. Launch tina in any workspace → ceremony runs, prints
   `Environment record updated (ENVIRONMENT.md).`
3. `find . -name ENVIRONMENT.md` → nothing; restart tina →
   `No ENVIRONMENT.md yet — the environment agent will populate it…`
   again, plus another provider request in the stub log.

## Fix direction

Success should be conditioned on the record's presence/actual change:
first load → `EnvironmentRecord.exists(project)` after the run; warm load →
mtime/digest change of the file. On failure, keep the warning branch and
do NOT `store.record()` (the region stays stale, which is the truth).

## Acceptance

- Unit test: a runner whose agent finishes text-only leaves the region
  stale and returns false; the coordinator's message is the warning one.
- Live: with the stub, the ceremony reports non-completion and does not
  stamp tracking.json fresh.

## Close (2026-08-17)

Fixed as proposed: `EnvironmentRunner.run()` snapshots the record's bytes
before the run, and success now additionally requires `_recordAdvanced` —
present after a first-load population, content-changed after a re-verify
(bytes, not mtime: deterministic in tests and immune to touch-without-
change). Unreadable/vanished record → cannot prove a change → false.
The coordinator's failure message reworded to "environment agent did not
update ENVIRONMENT.md" (covers finished-but-wrote-nothing as well as
aborted). Tests: prose-only first load (region stays stale, no tracking
entry), prose-only warm re-verify (unchanged bytes → false), warm rewrite
(changed bytes → true, region current). Root suite 543 green (+3).
Live stub repro, both legs: ceremony prints the warning branch, no
ENVIRONMENT.md anywhere, no tracking.json stamp, one provider request per
launch, honest re-run on restart.
