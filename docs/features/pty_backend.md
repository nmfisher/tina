# PTY backend (terminal panel phase 1)

Implemented and released in v0.6.30. This is an API reference and usage example,
not a list of outstanding tasks. See the [remaining terminal implementation
plan](terminal_panel_plan.md) for the emulator, rendering, input, and UI work.

The backend is in `packages/tina_engine/lib/src/terminal/`. It has no console,
notcurses, agent, or approval-policy dependency. The shell-panel controller will
own a `PtyConnection`; there is no `/term` command in this phase.

## Runnable shell example

On Linux or macOS, save this as `tool/pty_example.dart` in a checkout at
v0.6.30 or later and run `dart run tool/pty_example.dart` after resolving the
repository's dependencies. It starts an interactive shell on its own PTY,
sends a command followed by `exit`, and prints the captured transcript with
control characters escaped. It does not read your terminal's stdin or embed a
UI. The import is the current internal engine API.

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tina_engine/src/terminal/pty_runner.dart';

Future<void> main() async {
  final connection = await const PtyRunner().spawn(PtySpawnRequest(
    executable: '/bin/sh',
    arguments: ['-i'],
    workingDirectory: Directory.current.path,
    environment: {
      'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
      if (Platform.environment['HOME'] case final home?) 'HOME': home,
      'TERM': 'dumb',
      'PS1': '> ',
    },
    rows: 24,
    cols: 80,
  ));

  final transcript = StringBuffer();
  final outputDrained = Completer<void>();
  final subscription = utf8.decoder.bind(connection.output).listen(
    transcript.write,
    onError: (Object error, StackTrace stack) {
      if (!outputDrained.isCompleted) {
        outputDrained.completeError(error, stack);
      }
    },
    onDone: () {
      if (!outputDrained.isCompleted) outputDrained.complete();
    },
  );

  // Observe exit and stream failures immediately, even while writing input.
  final finished = Future.wait<Object?>([
    connection.done,
    outputDrained.future.then<Object?>((_) => null),
  ]).timeout(const Duration(seconds: 10));
  // Register an error handler now; the awaited future below still reports it.
  unawaited(finished.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  try {
    final delivered = await connection.write(
      utf8.encode('echo hello-from-pty\nexit\n'),
    ).timeout(const Duration(seconds: 10));
    if (!delivered) throw StateError('Shell exited before input was delivered');
    final results = await finished;
    stdout.writeln('exit: ${results.first}');
    stdout.writeln(jsonEncode(transcript.toString()));
  } finally {
    try {
      await connection.close();
    } finally {
      await subscription.cancel();
    }
  }
}
```

The output includes `hello-from-pty` and exit status 0; the PTY may also echo
the submitted commands and shell prompts. This example uses `TERM=dumb`
because it has no emulator. A real panel must parse bytes into its own grid;
forwarding child output to `stdout` would let the child overwrite Tina's UI.

For a panel, replace transcript capture with incremental emulator feeding,
send encoded input and query replies through one ordered writer, and call
`connection.resize(rows, cols)` only for positive interior dimensions. Connect
view removal and application shutdown to awaited `connection.close()`. See
the plan's controller phase for startup/close races and the final-output gate.

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
