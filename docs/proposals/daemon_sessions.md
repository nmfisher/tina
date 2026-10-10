# Daemon sessions — headless engine, attaching front ends

Status: **proposed**. Nothing here is implemented. Written against the
tree at the time of `docs/ARCHITECTURE.md`'s rewrite (v0.9.x, engine2
packages); file references were checked in source, not remembered.
Date: 2026-10-10.

Related: [`remote_answerable_approvals.md`](remote_answerable_approvals.md)
designs the approvals half of this story (`tina serve`, ask records,
answer ingress). This document is about the process split — sessions owned
by a long-lived headless process, front ends that attach and detach. The
approvals proposal's Part 3 verdict ("a daemon is the right goal,
assembled from pieces") still holds; where the two documents overlap, the
fail-closed and who-denied corrections there apply here unchanged.

## The idea

Today `tina` is one process: it assembles the app (`TuiAssembly.start`),
starts or resumes a `Host`, and renders it. Closing the terminal ends the
session; a long turn dies with the window.

The proposal: run the engine as a **daemon**. The daemon owns one `Host`
per live session — the loop, the tools, the sandbox, the log writer. The
TUI becomes a **client** that attaches over a Unix domain socket, streams
the session, sends input, and detaches without ending anything. A session
outlives any front end; `--resume` reattaches instead of rebuilding.

```
today:   tina = assembly + host + loop + renderer   (one process)

after:   tina (client)  ──socket──►  tina daemon
                                       ├─ host/loop  (session A)
                                       ├─ host/loop  (session B)
                                       └─ session store (single writer)
```

## What already exists (verified)

| Needed | Status |
|---|---|
| Terminal-free engine | Yes — `tina_engine_2` `AgentLoop`, `tina_host` `Host` |
| App without a screen | Yes — `TuiAssembly.start` with injectable `Terminal`/writer; the `--prompt` path proves it runs with no TTY |
| Replay on attach | Yes — the log listener's `LogEvent.replay` vs `appended`; listeners get the existing log then live entries |
| Sequence numbers | Yes — entries carry `seq`; resync after reconnect is a `seq` compare |
| Streaming watch events | Yes — `onWatch` / `_ObservedProvider` seam in `assembly.dart` |
| Single-writer sessions | Yes — the loop is the only log writer; `tina_sqlite` sets WAL + `busy_timeout=5000` |
| Config hot-reload across processes | Yes — the scoped settings stack watches config files (`onConfigurationChanged`) |
| Ask seam | Yes — `Terminal.ask` parks a completer; a pending future can hold a turn for hours |

## Target architecture

- **Daemon** owns one `Host`/assembly per live session. Only the daemon
  writes session logs (the loop is the single writer — this invariant is
  why the daemon must own sessions rather than proxy writes from a
  TUI-side engine).
- **TUI is a client.** `tina` with no args: connect + attach if the
  workspace socket exists; otherwise start the daemon or fall back to
  today's embedded mode (kept as the escape hatch and the test path).
- **Protocol:** newline-delimited JSON over a Unix domain socket, one
  versioned handshake. Client→server: `list`, `create`, `resume`,
  `attach`, `offerInput`, `answerAsk`, `cancel`, `switchModel`, `detach`.
  Server→client: replayed entries, appended entries (the log listener
  forwarded), watch events, running/idle status, asks. Reconnect: the
  client sends its last seen `seq`; the daemon replays the gap.
- **Authorization is the socket:** per-workspace socket path under a
  `0700` directory; same user only. v1 is same-machine by design.

## The hard parts, honestly

1. **The client interface is the long pole.** `TuiSession` and `app.dart`
   reach straight into the assembly: settings stack, plugin manager
   attach/detach, tools mode, providers panel, model catalog. A
   `SessionClient` seam with two implementations (in-process = today,
   socket = daemon) is required. Note this *satisfies* the "no interface
   without a second implementation" principle rather than violating it —
   but `settings_panel.dart` alone is ~59KB of surface.
2. **Scope protocol v1 to session operations.** Settings and plugin
   changes already round-trip through config files plus the watcher: a
   client that edits settings writes the file, the daemon's watcher picks
   it up and pushes `onSettingsChanged`. The whole settings API stays out
   of the wire protocol. Biggest scope cut available.
3. **Asks across the wire.** Ask event → client dialog → answer message →
   parked future resolves. No durable ask store is needed for live
   attach/detach v1. A **detached** session that hits an ask must fail
   closed and record the denial as unattended (`decidedBy: 'unattended'`)
   — recommendation 1 of the approvals proposal, a small change.
4. **Tool execution moves into the daemon.** Sandbox, child processes,
   `process_launcher` all run server-side with the daemon's privileges.
   Acceptable for same-machine v1. File-name completion in the client
   reads the workspace directly; needs an RPC only if clients ever run
   remotely.
5. **Lifecycle:** idle-session GC, `tina kill`, per-workspace socket path,
   `/update` restarting the daemon while clients reconnect, `--resume`
   listing routed through the daemon when it is up. WAL makes a second
   reader tolerable; a second writer is not.
6. **Multi-attacher policy:** v1 allows one driving client; other
   connections are rejected or read-only. Sharing foreground state
   between front ends is a product decision — deferred, as the approvals
   proposal defers it.

## Refactors first (each lands green)

1. **Split `tina_tui` into `tina_assembly` + `tina_tui`.**
   `TuiAssembly` is the application, not TUI code: config loading,
   settings stack, plugin registry, provider wiring, sandbox setup,
   session start/resume. The daemon needs exactly this and none of the
   rendering. The import graph is already clean in this direction: no
   assembly file imports a renderer file, and the `*_tui` plugin
   packages depend only on `tina_console`, never on the front end.

   Move to `tina_assembly` (terminal-free): `assembly.dart`,
   `assembly_config.dart`, `configured_provider.dart`,
   `provider_config.dart`, `plugin_catalog.dart`, `plugin_settings.dart`,
   `scoped_config.dart`, `settings_catalog.dart`, `settings_stack.dart`,
   `config_document.dart`, `tui_terminal.dart` (rename
   `buffered_terminal.dart` — it is a text buffer plus ask queue),
   `mcp_console_plugin.dart`, `process_launcher.dart` (daemon-side; the
   client sees only its output).

   Keep in `tina_tui`: `app.dart`, the views/panels (`settings_panel`,
   `providers_panel`, …), `session_selection.dart`, `terminal_startup.dart`,
   `restart.dart`, `shell_completion.dart`, `cli.dart` (which becomes a
   router: daemon serve / client attach / embedded fallback / headless).

   Two known wrinkles, both fine: `plugin_catalog.dart` imports the
   `*_tui` plugin packages (they depend only on `tina_console`, so they
   move with it — they are plugins with TUI-shaped contributions, not
   front-end code), and `ModelCatalog` lives in `tina_chat_tui` (moves
   later or is re-exported; it is data, not rendering).

2. **Extract `SessionClient` inside `tina_tui`.** Define the interface;
   the in-process implementation forwards to the assembly; `app.dart` and
   the panels call only that. The socket implementation becomes the
   second implementation in step 4. This surfaces hidden couplings while
   they are cheap to fix, and the interface's methods *are* the wire
   protocol's surface.

3. **Make `cli.dart` a router.** It already maps flags to assembly
   options; add the mode decision (serve / attach / embedded / headless)
   ahead of assembly construction.

4. **Daemon package:** `tina_assembly` + socket server + session registry
   + protocol v1 (`list`, `create`, `resume`, `attach`, `offerInput`,
   entries, status).

5. **Asks over the socket** + the fail-closed rule for detached sessions.

6. **Remaining features:** mid-turn attach with watch streaming, cancel,
   reconnect with `seq` resync.

Steps 1–3 are pure refactors, no behavior change, no protocol. Later:
fold in the approvals proposal's durable ask store and other transports
(HTTP, bridges) once a second transport actually exists — do not create a
`tina_protocol` package for one wire format with one client.

## Deliberately not in v1

- Remote (non-local) clients — same-machine authorization only.
- Multiple simultaneous driving clients, foreground negotiation.
- Durable ask records / restart recovery of a waiting turn (approvals
  proposal, recommendations 2–7; the live in-memory path needs none of
  it).
- A second engine. Everything runs the same `AgentLoop`.
