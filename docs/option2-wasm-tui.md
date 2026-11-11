# Option 2 productionized: the full tina TUI inside the sandbox

Status: design + seam inventory (milestone report 1; implementation follows
orchestrator review). Spike evidence: `option2-ansi-spike-report.md`
(tina `codex/issue85-ansi-tui-spike` @ `1ccddb0`, wasm.dart
`codex/issue85-host-tui-spike` @ `cbd5cad`). This round's goal, per the
principal: **bare `tina-wasm-host` gives the FULL tina TUI from inside the
wasm sandbox; `--headless` (alias `--pipes`) gives the pipes protocol for
agents and scripts.**

## Branch topology (both repos)

- tina `codex/issue85-wasm-tui`: branched off `codex/issue85-ansi-tui-spike`
  (`1ccddb0`), merged `codex/issue85-capability-merger` code tip (`1946b39`,
  NOT the binary artifact commit `ace8ca4` — that stays on the
  capability-merger branch). Merge: clean, `bf866d3`.
- wasm.dart `codex/issue85-wasm-tui`: branched off
  `codex/issue85-host-tui-spike` (`cbd5cad`), merged
  `codex/issue85-capability-merger` (`377d88d`). Merge `fefb33b`: conflicts
  in `main.rs` + `Cargo.toml` resolved by combining — the capability side's
  embedded-only thin main keeps the headless leg; the spike's `tui.rs`
  carries over as `tina_wasm_host::tui::run_bytes(bytes)` (component from
  build-time embed, not a path). `build.rs` now embeds a second component
  (`TINA_WASM_HOST_TUI` → `OUT_DIR/tui.component.wasm`, same
  rerun-if-changed staleness fix the engine got). `main.rs` dispatches:
  default → TUI, `--headless`/`--pipes`/`--tui` parsed (design-stage wiring;
  production TUI guest + failure channel are implementation milestones).
  Host crate 54/54 + integration suites green on the merged tree.

Shared-base fact that makes this cheap: both spike branches fork from the
same bases the capability branches fork from (tina `51cec2f`, wasm.dart
`5bb587b`), so the merges contain no semantic conflicts — the spike's
console seams and the merger's WIT/ports live in disjoint files except
`main.rs`/`Cargo.toml`, resolved above.

## The full-app closure: what wasm-clean already exists

The engine guest (`tina_wasm/bin/engine.dart`) already boots the whole
`SessionAssembly` inside the component: config from the stage-5-shaped
snapshot preopen, HTTP/policy/process over `tina:http@1.1.0` /
`tina:policy@1.0.0` / `tina:process@1.1.0`, plugins over `tina:plugin-host`,
`compileCapabilities: false` (the host owns the document). The TUI guest is
a **sibling composition root of the same assembly** — not a new engine: the
delta between the pipes closure and the TUI closure is exactly the front-end
layer (`tina_tui`, `tina_console`, `tina_host`, `fuzzy_ranker`).

Verified wasm-clean already (grep evidence, merged tree):

- `fuzzy_ranker`: pure Dart, zero `dart:io`/`dart:ffi` — the spike report's
  concern was stale; nothing to do.
- `tina_host`: no `dart:io`/`dart:ffi` — clean.
- `terminfo_environment`, `init_reply_guard`, `discard_unbinder`: only
  imported by `notcurses_backend.dart` (FFI, outside the wasm closure once
  the backend choice is `ansi`).
- The chat-region machinery the spike exercised (`Screen.requestChatPresentation`,
  `ScrollingTextRegion`) is the REAL app's path: `region.dart` calls it; the
  real layout arrives via `runApp` → `ScreenLayout.fromSize(..., split:
  false)` (the production app already runs the unsplit layout). So "wire the
  chat region into the real layout" = make the real closure compile + run
  under wasm; no bespoke spike painting survives into production.

## Seam inventory (the implementation work items)

1. **`tina_tui/lib/src/terminal_startup.dart`** — `TerminalStartupSnapshot`:
   pure FFI (`dup`/`dup2`/`fcntl`/`tcgetattr`/`tcsetattr` via
   `DynamicLibrary.process`) + a `stdout.write` of reset sequences. Design:
   conditional-import seam (the `stdio`/`platform_env` pattern):
   `terminal_startup_io.dart` keeps today's code byte-for-byte native;
   `terminal_startup_unsupported.dart` answers a no-op snapshot — the HOST
   owns the terminal under wasm (it enables raw mode before the stdin pump
   and its Drop guard restores on every exit path), so the guest's
   snapshot-restore dance is meaningless there. `StartupTerminal`
   (`app.dart:289`) wraps this seam; `runTui(startup:)` already takes it as
   a nullable parameter, so the guest passes nothing.
2. **`tina_console/lib/src/line_editor.dart`** — dead `import 'dart:io'`
   (its `io.` uses are gone per the spike); delete the import.
3. **The barrel `tina_console/lib/tina_console.dart`** — two wasm-hostile
   exports:
   - `src/terminal_bg.dart` (`Platform.isMacOS/isLinux`, `stdin`, `stdout`):
     seam it like `ansi_capable`/`input_log` were seamed —
     `platform_env`-based under wasm (env heuristic + `TerminalBg.dark`
     fallback), dart:io path native.
   - `src/backend/notcurses_probe.dart` (`dart:ffi` + `dart:io`): FFI is
     out of the wasm closure entirely. Design decision (flagged for
     review): remove the export from the shared barrel into a
     `tina_console_native.dart` barrel; the native CLI's backend probe
     (`backend: 'auto'` path in `apps/tina_cli`) imports the native barrel;
     wasm closure imports only the shared one. Conditional exports were
     rejected: they can't hide a library with a different import graph.
   - `console_image.dart` pulls `package:image` — 4.10.1 keeps `dart:io`
     behind conditional imports (`_file_access_io.dart`), so it SHOULD
     resolve under dart2wasm; verified at implementation time, and if it
     does not, it joins the native barrel (image rendering is optional
     under wasm round 1).
4. **`tina_tui/lib/src/app.dart`** — direct `dart:io` globals that bypass
   the existing `Stdio` seam: `io.stdin.echoMode/lineMode` (lines 80-83),
   `io.ProcessSignal.sigint` (99), `io.stdout.terminalColumns/terminalLines`
   (105-106). Design: extend the `Stdio` seam with the three operations the
   app actually uses — `terminalSize()`, `setEchoMode(bool)` /
   `setLineMode(bool)` — native impl over `dart:io`, WASI impl backed by
   `tina:term/tty.get-size` (echo/line modes are no-ops: the host's raw-mode
   pipe is the truth) and `watchSignal` already exists on the seam.
5. **`tina_tui/lib/src/completion_sources.dart`** —
   `GitFileCompletionSource` runs `git ls-files` (`Process.run`) and walks
   `Directory`/`FileSystemEntity`. Round 1 decision (flagged): wasm variant
   returns null (the `@` file picker is silently absent — consistent with
   the input_log/paste_audit drops). Follow-up, not this round: route it
   through the `tina:process` port so completion is capability-gated like
   every other spawn.
6. **Guest-to-host failure channel (spike finding 4)** — today a guest Dart
   exception kills the guest task without returning a result and the host's
   `run` call parks forever; the watchdog (Ctrl-C injection) is the only
   exit. Design:
   - `tina:term` gains a second interface, `crash`:
     `fail: func(message: string)`. Same package, so the spike's finding 7
     (witgen rejects a world importing its own package) does not apply.
   - Guest: the composition root wraps the app body in
     `runZonedGuarded`; `onError` calls `crash.fail(message)` (the zone
     still runs on the dead task's error), then invokes the WASI `exit`
     import non-zero as the structural backstop.
   - Host: `crash.fail` records the message and signals the parked wait
     (a `tokio::sync::Notify`/watch the `run` future selects on), tears
     down the store, restores the terminal (the existing Drop guard), and
     exits non-zero with `guest crashed: <message>` on stderr. The message
     must survive even if the guest wedge-persists — fail-before-wait
     ordering makes that hold.
   - Epoch machinery (`epoch_deadline_trap`, ticker-before-instantiation —
     spike findings 1/2) and the Ctrl-C watchdog stay as the backstops for
     hangs and wedges; the failure channel covers the *crash* case
     structurally.
   - Note: the pipes engine guest has the same latent parking exposure
     (its `run` export is the same shape). Out of scope this round;
     verify + backport as a follow-up if confirmed.
7. **Production TUI component** — new package `packages/libraries/tina_tui_guest`
   (the `tina_tui_spike` package stays untouched as spike evidence):
   - WIT world: `include wasi:cli/command@0.3.0` + import
     `tina:term/tty@0.1.0`, `tina:term/crash@0.1.0`,
     `tina:http@1.1.0`, `tina:policy@1.0.0`, `tina:process@1.1.0`,
     `tina:plugin-host@0.1.0` (the engine world's import set + tty/crash)
     + `export wasi:cli/run`. Bindings via `wasm_tools witgen`, component
     via `wasm_tools compile` (the engine build's recipe, edge SDK +
     branch-tip wasm_tools via the gitignored overrides).
   - `bin/tui.dart`: the `engine.dart` composition root's assembly boot
     (snapshot config, `compileCapabilities: false`, ports, plugin
     registry) + the native TUI path's front end: in-process
     `TuiSessionHandle` (`tui_session.dart` wrapper, the same surface
     `runTui` drives natively), `runTui(view, backend: 'ansi',
     startup: null, resizes: <tty-poll stream>)`. Resize: 250 ms dart
     Timer polling `get-size` (spike-proven); push-on-SIGWINCH stays a
     documented follow-up.
   - Size estimate: engine component 2.18 MB + front-end closure →
     roughly 3.5-5 MB; no wall expected (spike stopped at 794 KB for the
     demo, engine closure already proven at 2.18 MB).

## Host-side production wiring (wasm.dart)

- `main.rs` (resolved in the merge, completed in implementation): default →
  embedded TUI via `tui::run_bytes`; `--headless`/`--pipes` → the engine leg
  exactly as today. No component path arguments on either leg (embedded-only
  directive); dev loop = set `TINA_WASM_HOST_TUI` and rebuild (build.rs
  watches the file).
- `tui.rs` production rewire: replace the spike's bare Store with the
  `run_guest` machinery — discovery snapshot preopens (config mount,
  models.dev cache, HOME), `HostState` with the tina:http/policy/process/
  plugin imports on the shared linker (harmless for the engine guest, which
  simply doesn't import tty/crash), raw mode + stdin pump + tty/crash host
  imports layered on top. Raw mode enabled before the stdin pump; Drop guard
  restores across return/trap/epoch-kill exactly as the spike proved.
- Windows: termios is POSIX; `--tui` on a non-POSIX host answers a clear
  error and points at `--headless`. Not exercised this round.

## Validation plan (milestone 3, tmux)

1. **Interactive parity**: native `tina` TUI vs `tina-wasm-host` bare, same
   scripted key script in tmux panes: paint, typing/echo, Enter, Escape,
   Ctrl-L, `/plugins` status (in-process registry — but plugin session
   open/close crosses `tina:plugin-host`), model picker, quit. Byte-level
   capture compared for structure (alt-screen enter/leave, save/restore
   cursor, diff-paint rows), not byte-equality (backend differs).
2. **Resize**: `tmux resize-pane` mid-session — guest poll →
   `Screen.resize`, layout reflows; status strip follows.
3. **Clean restore on quit**: alt-screen leave + cooked modes + host exit 0.
4. **Epoch kill**: `TINA_TUI_EPOCH_TICKS` — trap surfaced, terminal
   restored, host exit 3.
5. **Failure channel**: a guest-component leg that throws mid-run → host
   reports `guest crashed: …`, terminal restored, non-zero exit, no parking
   (the spike's finding 4 scenario, now structural).
6. **Headless leg unchanged**: `--headless` pipes exit test both legs PASS
   (the stage-5 harness), so the default switch regresses nothing for
   agents/scripts.
7. **Suites**: tina_console (1170), tina_tui (52), tina_chat_tui (126),
   fuzzy_ranker, tina_wasm, tina_capability, app-suite baselines, host
   crate 54/54 + new tests: tty/crash host imports, failure-channel
   end-to-end, TUI-guest boots-to-ready smoke, `--headless` dispatch unit
   tests. No test weakened; any superseded assertion updated with notes.

## Milestones

1. **This report** — design + seam inventory + branch topology, for
   orchestrator review.
2. Implementation: seams (1-5), failure channel (6), guest package +
   component (7), host rewire; tests green per commit; identities recorded
   per commit batch.
3. tmux validation + parity + suites; final report + ledger.

## Open questions for the orchestrator (round-1 defaults chosen; overrides welcome)

1. Branch topology as above (off the spike per the principal, merger merged
   in) — approve the cross-feature merges?
2. Flag name: `--headless` primary + `--pipes` alias (goal text offered
   either) — both accepted from day one.
3. `notcurses_probe` out of the shared barrel into `tina_console_native.dart`
   — acceptable split?
4. `@` git file completion dropped under wasm round 1 (tina:process routing
   deferred) — acceptable?
5. `crash.fail` interface name in `tina:term` — or prefer `tina:runtime`
   package? (One extra package for one function; keeping it in `tina:term`
   is cheaper.)
