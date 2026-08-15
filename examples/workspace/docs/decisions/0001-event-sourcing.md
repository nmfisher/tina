# ADR 0001: Event sourcing for task state

Date: 2025-11-02
Status: Accepted

## Context

Tasks change rarely but auditably: we want to know not just what a task's
title is, but what it was last week and who changed it. A plain CRUD table
loses that history.

## Decision

Store an append-only stream of `TaskEvent`s (`TaskCreated`, `TaskRenamed`,
`TaskCompleted`, `TaskReopened`) and derive current state by folding the
stream per task, newest event wins.

## Consequences

- Deletes are expensive (full rewrite), so they're rare and explicit.
- The log doubles as an audit trail and a fixture corpus (`data/samples.ndjson`).
- Replays must be deterministic — hence the injected `Now` in core's
  `clock.dart`; wall-clock time may only be read at the edges.
