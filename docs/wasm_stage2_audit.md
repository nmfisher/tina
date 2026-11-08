# Wasm stage 2 audit — I/O in the engine

Stage 2 of the dart2wasm port (`asb/wasm-stage2-io-ports`). Wasm standalone
mode has no `dart:io` (files, sockets, HTTP, process spawn), no `dart:ffi`
and no isolates. This audit inventories what the engine uses today, which
port covers each use, and what a later stage must handle instead.

## What "engine packages" means here

The wasm target is the headless agent loop — no TUI. The packages that form
that engine (the terminal-free runtime core plus its provider package):

| package            | role                              | in this stage |
|--------------------|-----------------------------------|---------------|
| `tina_core`        | shared contracts                   | cleaned (was already pure) |
| `tina_engine_2`    | agent loop                         | cleaned (clock port) |
| `tina_host`        | session lifecycle                  | cleaned (clock + random ports) |
| `tina_llm`         | model providers                    | cleaned (http + fs + env ports) |
| `tina_settings`    | config snapshots (host dependency) | already clean, ratcheted |

Everything else in `packages/plugins/*` is a mounted contribution, not the
engine: the wasm assembly can mount a subset, and the deeply native plugins
(tools sandbox, persistence, MCP transports, self-update) are deferred to
later stages — per-package findings below say which.

The ratchet added this stage (`noDirectIoPackages` in
`tool/repository/policy.json`) bans `dart:io` imports from the `lib/` trees
of exactly these five packages. `test/` trees are exempt on purpose: engine
tests run on the VM and legitimately use `Directory.systemTemp`, sockets and
child processes to test native behavior; they are not compiled into the wasm
module.

## Inventory — engine packages (pre-change)

### `tina_core` — clean
No `dart:io`, no `dart:isolate`, no `dart:ffi`, no `Platform`, no
`DateTime.now`/`Random` in `lib/`. The ports landed here because core is the
dependency-free seam every engine package already shares.

### `tina_engine_2`
| use | site | covered by |
|-----|------|-----------|
| `DateTime.now()` | `loop.dart` (`_now()` — 12 entry timestamps), `session_observation.dart` (tool started/elapsed) | `ClockPort` (default `SystemClock`, dart:core — wasm-safe) |

`Stopwatch` in tool execution stays: it is `dart:core`, not `dart:io`, and
works in wasm.

### `tina_host`
| use | site | covered by |
|-----|------|-----------|
| `Random.secure()` | `host.dart` (session epoch id), `session_questions.dart` (question epoch id) | `RandomPort` (default `SystemRandom`, dart:math) |
| `DateTime.now()` | `host.dart` (`started_at`, generated session ids ×2), `session_questions.dart` (question expiry) | `ClockPort` |

### `tina_llm` — the only engine package importing `dart:io`
| use | site | covered by |
|-----|------|-----------|
| `HttpClient` (POST/GET + SSE streaming) | `http.dart` `IoHttpEndpoint`; default-constructed by `anthropic_provider`, `gemini_provider`, `openai_compatible_provider`, `descriptor.build` | `HttpClientPort` (the existing `HttpEndpoint` seam, now a core port); native impl `IoHttpEndpoint` moved to `tina_io` and injected by the app |
| `Platform.environment` | `anthropic_provider.dart` (token + `TINA_LLM_ENDPOINT` resolution), `models_dev.dart` (cache dir) | `EnvironmentPort`; native impl in `tina_io`; engine default is fail-closed |
| `File`/`Directory` | `models_dev.dart` (models.dev catalogue cache read/write/stamp), `cached_providers.dart` (legacy cache read) | `FileSystemPort`; native impl in `tina_io`. `cached_providers.dart` was app-only startup glue and moved to `apps/tina_cli` (it may keep `dart:io`) |

### `tina_settings` — clean
No I/O. Ratcheted so it stays that way.

## Inventory — non-engine packages (deferred, per stage)

These are mounted contributions; none is part of the stage-2 wasm build.

| package | `dart:io` in lib | dominant uses | port / stage |
|---------|------------------|---------------|--------------|
| `tina_tools` | 24 files | files (already behind its own `FileSystem` seam + `IoFileSystem`), process spawn (`ProcessRunner`, OS sandbox/bwrap, PTY trees), `Platform` ×22 | `FileSystemPort`/`ProcessPort` are the contract; migrating `tina_tools` onto the core ports and splitting its native adapters out is **stage 3** (tools) |
| `classification` | 12 files | file stores, `http` package, TOML config reads | stage 4 — same ports; the pub `http`/`toml` deps also need swap-or-shim |
| `tina_index` | 6 files | file walking | stage 4 |
| `tina_persistence` | 5 files | sqlite + jsonl stores; **`Isolate.run` ×3** (`history_tools.dart`) | stage 5 (persistence): store seam or wasm sqlite; isolates do not exist in wasm — replace with plain async |
| `tina_mcp` | 2 files | stdio transports spawn MCP servers; HTTP transport | stage 5 (MCP): `ProcessPort` + `HttpClientPort`; a wasm assembly cannot host stdio servers |
| `tina_self_update` | 3 files | downloads release tarballs, verifies, replaces binary | **never in wasm** — plugin stays native-only, not mounted |
| `tina_subagents` | 2 files | spawns child tina processes | stage 3+: a wasm assembly mounts subagents differently (in-engine) or not at all |
| `tina_sqlite` | 1 file + `package:sqlite3` | **`dart:ffi` (transitive, via sqlite3)** | stage 5: ffi does not exist in wasm; wasm build must exclude the sqlite seam and mount a different store |
| `file_tree`, `attractor`, `tina_context`, `tina_file_resources`, `tina_shell`, `tina_step_limit`, `tina_workflows`, `tina_web_search`, `tina_goals`, `tina_mode`, `tina_providers`, `tina_approvals` (+rest) | 1–10 files each | file reads for config/context, small process helpers | stages 3–4, same ports |
| `tina_console`, `dart_notcurses`, `tina_tui`, `*_tui` | many | **`dart:ffi` (notcurses)**, terminals | never in wasm — the engine is headless by construction; `frontend-exclusion` in the architecture policy already keeps them out of the engine |
| `apps/tina_cli` | many | owns stdin/stdout, **signals** (`ProcessSignal`), **`exitCode`**, process restart, PTY | never in wasm — the composition root; a wasm build replaces this layer with its own assembly |

### Cross-cutting findings
- **Isolates**: `tina_persistence/history_tools.dart` is the only `dart:isolate`
  use in a non-terminal package (three `Isolate.run` calls). Not an engine
  package; stage 5 replaces them with plain `async` (the compute is JSON
  parsing — no need for real parallelism). No isolates in engine packages.
- **`dart:ffi`**: no direct engine use. Transitive via `package:sqlite3`
  (`tina_sqlite`) and `dart_notcurses` (terminal). Terminal packages are
  already excluded from the engine by the `frontend-exclusion` ratchet;
  sqlite is stage 5.
- **`Platform`**: engine uses are only `Platform.environment` (token/cache
  resolution) — `EnvironmentPort`. `Platform.pathSeparator`/`isWindows` uses
  live in `tina_tools` (stage 3) and the app.
- **Signals / `exitCode`**: exclusively `apps/tina_cli` (`cli.dart`,
  `restart.dart`, `process_launcher.dart`) — the process shell around the
  engine. A wasm host maps its own lifecycle; nothing to port.
- **Clock/random**: `DateTime.now`/`Random.secure` are `dart:core`/`dart:math`
  and compile under dart2wasm, so the engine would *build* without porting
  them — but the ports make the seams explicit, deterministic in tests, and
  overridable by a wasm host. Native behavior is unchanged (system defaults).

## Result of this stage

- Ports in `tina_core/lib/src/ports.dart` (exported as
  `package:tina_core/tina_core.dart`): `HttpClientPort` (+ close),
  `FileSystemPort`, `ProcessPort`, `ClockPort` (+ `SystemClock`),
  `RandomPort` (+ `SystemRandom`), `EnvironmentPort` — the last added by
  the audit above. `tina_llm` keeps `HttpEndpoint`/`HttpResponse` as
  typedefs over the core port so call sites and fakes read unchanged.
- Native implementations: `packages/libraries/tina_io` — `IoHttpEndpoint`
  (moved verbatim from `tina_llm/http.dart`), `IoFileSystemPort`,
  `IoEnvironmentPort`. `tina_io` is deliberately **not** an engine
  package; it is the native adapter the composition root injects
  (`configured_provider.dart`, `assembly.dart`). A wasm build excludes it
  and supplies its own port implementations.
- Call sites moved behind the ports:
  - `tina_llm`: all four provider constructors take an injected endpoint
    (fail closed at send without one); the Anthropic provider's token and
    `TINA_LLM_ENDPOINT` reads go through `EnvironmentPort`;
    `models_dev.dart` reads/writes its cache through `FileSystemPort` /
    `EnvironmentPort` / `ClockPort`; `isStale` became async (its stamp
    file is never written anywhere, so it always reported stale — the
    port conversion preserves that exact behavior).
  - `tina_engine_2`: every log-entry timestamp (`loop.dart`) and the
    observation activity stamps (`session_observation.dart`) go through
    `ClockPort`, injected into `AgentLoop`.
  - `tina_host`: session/question epoch ids through `RandomPort`,
    `started_at`, generated session ids and question expiry through
    `ClockPort`, both on `HostConfig` (and optional on `Host.child`,
    `SessionQuestions`), defaulting to the system implementations.
- Files moved:
  - `packages/tina_llm/lib/src/cached_providers.dart` →
    `apps/tina_cli/lib/src/legacy_provider_cache.dart` (app-only startup
    glue reading the process's own files; the app keeps `dart:io`).
  - `IoHttpEndpoint` `tina_llm/lib/src/http.dart` →
    `packages/libraries/tina_io/lib/src/io_http_endpoint.dart`.
- `ProcessPort` is defined but has no engine call site yet — `tina_tools`
  and `tina_mcp` are its consumers and migrate in stage 3+.
- Ratchet: `noDirectIoPackages` in `tool/repository/policy.json` +
  `policy.dart` — a direct `dart:io` import anywhere under an engine
  package's `lib/` is an analyze-time `service-io` failure
  (`tool/repository/test/no_direct_io_test.dart` pins the rule; the
  repo-wide check runs in CI through `import_boundary_test`).
- Test adjustments (mechanical, assertions untouched): endpoint fakes
  implement the port's `close()` (`tina_llm` helpers/provider tests,
  `tina_web_search`, app `config_parity_test`, `verify_local_config`);
  the models.dev cache tests pass the injected `IoFileSystemPort`.
