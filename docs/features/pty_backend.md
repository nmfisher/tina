# PTY backend (terminal panel phase 1)

The backend is in `packages/tina_engine/lib/src/terminal/`. It has no console,
notcurses, agent, or approval-policy dependency. The shell-panel controller will
own a `PtyConnection`; there is no `/term` command in this phase.

## Ownership and completion

`PtyRunner.spawn` starts a worker isolate. The C shim creates a new session and
controlling terminal, then execs the requested executable. A supervisor relays
the real child's status so the Dart VM's process reaper cannot steal it.
Handshake, output, status and worker-death events use one mailbox.

The worker owns the native descriptors and buffers. All terminal paths await
session shutdown and release native resources in `finally` before reporting
completion. `close()` is idempotent. Natural shell exit also cleans up remaining
owned descendants. `ChildProcessRegistry` stores the connection's awaited
cleanup callback as an application-shutdown fallback.

`PtySession` separates the TERM/grace/KILL lifecycle from transport. Its signal
adapter, clock and delay are injectable. Native session enumeration uses procfs
on Linux and libproc on macOS. Signals target individual live members of the
original session, including different job-control groups and groups whose
leader exited. Zombies count as dead. Enumeration failures are errors, not
successful empty snapshots. Deliberately detached sessions are outside ownership.

## Byte transport

Output is a **single-consumer ordered stream**. Consumers should feed one
terminal emulator, rather than independently subscribing multiple views.
`PtyOutput` retains startup bytes through natural completion. Each byte consumes
worker credit, replenished only when delivered to an unpaused consumer. No
listener and paused-listener cases therefore apply the same bounded backpressure.
Cancellation explicitly abandons that consumer's output and releases credits.

During shutdown, after owned writers are gone, the worker drains the finite
kernel tail even when the consumer is paused. The final tail has a separate
1 MiB safety cap: a detached process cannot keep close running or grow memory
indefinitely; exceeding the cap reports an error. Normal unread transport is
bounded by `maxQueuedOutput`; finalization can additionally retain this tail.

`done` means native transport cleanup and session termination are complete.
A paused or late consumer can still receive retained output and its stream's
done event afterwards. An active consumer receives output before exit status.

Writes are serialized, with one bounded chunk in flight and an acknowledgement
per chunk. `write()` returns false if exit/close interrupted delivery; true
means all bytes reached the PTY, not that the child processed them. Pending
writers settle on every terminal path.

## Validation

Pure unit tests exercise output pause/resume, late attachment, cancellation,
and termination deadlines without processes or real waits. Native tests cover
raw byte round trips, late output, paused producers, natural exit, spawn failure,
TERM/HUP-immune descendants with and without job control, and registry cleanup.
The engine CI runs these on Linux; the macOS job also runs the PTY suite before
building and smoke-testing the application bundle.
