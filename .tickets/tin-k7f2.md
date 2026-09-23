---
id: tin-k7f2
status: closed
deps: []
links: []
created: 2026-09-15
type: feature
priority: 1
assignee: Nick Fisher
tags: [terminal, pty, native]
---

# PTY backend for the interactive shell panel (Phase 1)

## Context

The interactive shell panel plan (`docs/features/terminal_panel_plan.md`)
needs a real PTY backend before any UI work. Phase 1 is "prove the native
process boundary": launch a child on a pseudo-terminal from Dart, get its
output and exit status, and shut it down cleanly. The fork-to-exec child path
must live in native code: after fork, a child of the multithreaded Dart VM
may only use async-signal-safe functions until exec.

## Proposal

1. A small in-tree C shim (`native/src/pty_shim.c`) that owns the whole
   fork-to-exec path: posix_openpt/grantpt/unlockpt, initial termios and
   window size, setsid + TIOCSCTTY controlling-terminal setup, signal mask
   and disposition reset, dup2 of the slave onto fd 0/1/2, execve, and
   exec-error reporting over a CLOEXEC pipe. All constants come from
   platform headers, so the same C builds on Linux x64, Linux arm64, and
   macOS arm64.
2. A native asset (build hook, same stack as dart_notcurses) so the shim
   loads identically under `dart run`, `dart test`, and AOT.
3. Dart-side `PtyRunner` / `PtyConnection` in
   `lib/src/terminal/`: no blocking read, no waitpid, no unbounded write on
   the UI isolate; worker isolate with wakeup/shutdown, bounded I/O queues
   with backpressure, short-write/EINTR/EAGAIN handling, idempotent close.

## Acceptance

Status: closed 2026-09-22. Phase 1 complete, merged as PR #53
(a3f008e). The original acceptance items passed their (flawed)
tests; review found six correctness defects, all fixed with
regression tests and merged in the same PR:

1. [x] Double exec: the fork-2 child AND the supervisor relay child both
   reached `child_exec`, so every spawn ran the command twice.
   (`e9b7f64`)
2. [x] Process-group termination: the shim's `pid <= 0` guard rejected
   negative pids, so `_killTree`'s group signals never landed; background
   descendants survived close. Now `kill(-pgid, …)` is used and verified
   to kill the whole group. (`cdab3d6`)
   NOTE (corrects an earlier note here): `kill(-pgid, sig)` IS valid on
   this kernel — a probe with a live spawned group succeeds. The EINVAL
   came from the shim's own guard, not the kernel.
3. [x] Drain starvation: the worker's drain loop never yielded on a
   would-block read, turning a 50ms close grace into ~4.6s. (`14970de`)
4. [x] Leaked ReceivePort: `_workerDone` was never closed, so a program
   that spawned and closed never exited. (`92758fd`)
5. [x] Startup output dropped: the broadcast output controller discarded
   events emitted before a listener attached. Now buffered (1 MiB cap)
   and flushed on listen. (`147c1f7`)
6. [x] Half-closed natural exit: after `done`, output was never closed and
   writes were still accepted. The worker now sends a `finalized` message;
   the main side closes output and refuses writes. (`cf31087`)

- [x] Child reports the PTY as stdin/stdout/stderr, receives the requested
      cwd and environment, and produces output and exit status on Linux.
- [x] Invalid executable or cwd, resize, partial I/O, immediate exit,
      repeated close, close during spawn, and a child ignoring termination
      all complete predictably.
- [x] An interactive shell can run and interrupt a foreground job without
      killing tina; shutdown leaves no owned test children or worker behind.
- [x] Tests allocate their own PTY: no `/dev/tty`, no `stdout.hasTerminal`.

## Implementation notes

- Shim (`native/src/pty_shim.c`): double-fork — the caller's direct child is
  a short-lived supervisor that waits on the real exec grandchild and relays
  both the grandchild's pid and its raw wait status back over pipes
  (`status_fd` in the spawn result). This defeats the Dart VM's
  wait(-1)-style reaper, which otherwise steals children under `dart test`
  and makes the caller's own waits fail with ECHILD.
- Termination: the child runs setsid(), so it is its own session AND
  process-group leader; `_killTree` signals `-pid` (SIGTERM to the group,
  bounded grace, SIGKILL to the group) and probes liveness with
  `kill(pid, 0)` (never reaps). A grandchild can hold the slave open
  forever, so after the SIGKILL escalation the worker closes the PTY
  unconditionally instead of waiting for an EOF that may never come.
- The status relay doubles as the death signal: once the supervisor writes
  (or dies without writing), the child is unrecoverable and the exit status
  is known (or forfeited as a signal death). No blocking native calls on the
  worker's event path; shutdown order is terminate → bounded isolate wait →
  kill → port teardown, so `close()` always returns.
- Verified on Linux x64 only; macOS/arm64 builds from the same C but is
  unverified.

## Tests

- `packages/tina_engine/test/terminal/pty_runner_test.dart`: 19 tests green
  (`dart test test/terminal/ --concurrency=1`), including regressions for
  all six defects above.
- `packages/tina_engine/test/terminal/pty_reap_test.dart`: regression test
  for exit-status reporting under the test runner's child reaper.
- Root suite: 791 passing.
