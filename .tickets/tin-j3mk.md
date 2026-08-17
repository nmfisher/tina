---
id: tin-j3mk
status: closed
deps: []
links: [tin-r2vd, tin-v6tq]
created: 2026-08-15T00:00:00Z
closed: 2026-08-17T00:00:00Z
type: bug
priority: 2
assignee: Nick Fisher
tags: [tui, notcurses, shutdown, crash]
---
# Teardown segfault: use-after-free after notcurses_stop

## Context

Found by the tui-smoke container run (2026-08-15). After quitting the notcurses TUI, the process crashes with SIGSEGV in `notcurses_stdplane` — a use-after-free on a background thread after `notcurses_stop`. The run printed "Aborted"; render and quit both worked, so this is a shutdown race.

## Cause (root-caused 2026-08-17)

The native input pump thread (`pump_main`, `dart_notcurses/native/src/input_pump.c`)
loops on `poll` → `notcurses_get_nblock(pump->nc)` for the whole session, and the
**only** join is `cocoon_input_pump_stop`, reachable solely from
`NotcursesInputBackend.dispose()`. That dispose ran on exactly one path:
`LineEditor.disposeInput()` inside `_teardownUi` (the normal exit).

Every *emergency* stop path — `emergencyTerminalRestore()`, reached from the
SIGTERM/SIGHUP reaper (`bin/tina.dart`), any error escaping the TUI run loop, and
the zone guard — called `screen.leaveAltScreen()` → `notcurses_stop` with the pump
thread still alive. The thread's next `notcurses_get_nblock`/`inputready_fd` on
the freed context is the UAF; `notcurses_get`'s internal deref of the std plane
matches the recorded `notcurses_stdplane` frame. Aggravated by input in flight
(the injected terminal replies of the tin-r2vd era) because that keeps the thread
cycling through `get_nblock` instead of parked in `poll`.

Live confirmation under gdb (attach after the asset lib dlopens — pending
breakpoints never resolve with `dart run`): threads show `pump_main` AND
notcurses' own `input_thread`; only the latter is joined by `notcurses_stop`.

## Fix

`NotcursesBackend` is now the single ordering choke point
(`packages/tina_console/lib/src/backend/notcurses_backend.dart`):

- `createInputBackend()` registers each backend it hands out.
- `leaveAltScreen()` disposes them all — joining the pump thread — BEFORE
  `_platform.stop()` frees the context, with each dispose in a try/catch so a
  failing join can never block terminal restoration.
- `dispose()` is idempotent, so the normal path (editor already disposed its
  backend first) pays nothing; the emergency, error, and init-failure paths get
  the same join for free because they all funnel through `leaveAltScreen`.

## Verification

- `packages/tina_console/test/notcurses_backend_platform_test.dart` — group
  "NotcursesBackend teardown ordering (tin-j3mk)": dispose-before-stop ordering,
  the emergency shape (no prior disposeInput), idempotency on the normal path,
  every handed-out backend joined, and a throwing dispose not blocking stop.
  The stub's dispose records into the platform's ordered call log.
- tina_console suite 715/715, root suite 540/540, no new analyzer issues
  (the 3 warnings pre-date this change).
- Live binary proof (gdb attach, real notcurses): on `/quit`,
  `cocoon_input_pump_stop` hits BEFORE `notcurses_stop`.
- `tool/crash_teardown.sh` (new): SIGTERM during a reply burst, SIGTERM during a
  keystroke flood, and `/quit` during a burst — 12 runs total across the session,
  all clean exits, no SIGSEGV/"Aborted", terminal restored.

## Notes

- A userland SIGSEGV never reproduced on this host (glibc keeps the freed pages
  mapped, so the UAF reads succeed silently); the container's allocator faulted.
  The race was proven structurally (thread states under gdb + the sole-join
  reachability above) and the fix verified by breakpoint ordering instead.
- gdb gotchas recorded for future hunts: pending breakpoints don't resolve for
  the dlopen'd asset lib under `dart run` (attach after render instead), and a
  passed-through SIGTERM never reaches Dart's watcher under an attached gdb —
  it kills the VM. Drive signal-path checks without gdb.

## Acceptance criteria

- [x] Clean exit: no crash, no "Aborted" after quit — normal and emergency paths.
- [x] Teardown orders the stop before the background thread's last plane access
      (join first — asserted in tests and observed live under gdb).
- [x] Regression tests (5) added; existing suites keep passing.
