---
id: tin-k7f2
status: open
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
   with backpressure, short-write/EINTR/EAGAIN handling, idempotent close,
   tree termination with bounded grace, ChildProcessRegistry fallback.

## Acceptance

- [ ] Child reports the PTY as stdin/stdout/stderr, receives the requested
      cwd and environment, and produces output and exit status on Linux.
- [ ] Invalid executable or cwd, resize, partial I/O, immediate exit,
      repeated close, close during spawn, and a child ignoring termination
      all complete predictably.
- [ ] An interactive shell can run and interrupt a foreground job without
      killing tina; shutdown leaves no owned test children or worker behind.
- [ ] Tests allocate their own PTY: no `/dev/tty`, no `stdout.hasTerminal`.
