# MCP clients via the plugin architecture

Status: proposal. Reference implementation: opencode's
[`packages/opencode/src/mcp/`](https://github.com/sst/opencode/tree/dev/packages/opencode/src/mcp)
(`index.ts`, `catalog.ts`), adapted to tina's plugin runtime.

## Goal

tina speaks MCP as a CLIENT: servers declared in config are spawned or
dialed, their tools are listed, and those tools appear to the agent as
ordinary tina tools — same registry, same approval flow, same permission
policy, same safe-mode behavior. The integration is a plugin: adding or
removing MCP support is a profile selection, and replacing the
implementation is a plugin swap. No edits to `Agent.run`,
`tui_coordinator.dart`, or the project tool catalog — but v1 does need
three small engine additions (see
[Wiring](#wiring-where-the-tools-actually-land)): a merge of
execution-scope tool contributions into the main agent's registry, a
`stdin` member on `RunningProcess`, and a published
process-runner service key.

## Scope

**v1 (this proposal):**

- Transports: **stdio** (spawn a server process, JSON-RPC over
  stdin/stdout) and **remote** (Streamable HTTP: one POST per request,
  JSON or `text/event-stream` response, `Mcp-Session-Id` honored).
- Protocol: `initialize`/`notifications/initialized`, `tools/list` (with
  `nextCursor` pagination and the lenient `outputSchema` retry opencode
  does), `tools/call`, `notifications/cancelled`, `ping`, `roots/list`
  request handling (answer with the project root), `logging/message`
  notifications (routed to tina's log channel), `tools/list_changed`
  (re-list, refresh `/mcp` and the status line — registration stays
  frozen at startup; see the manager section).
- Tool adapters: every MCP tool becomes one tina `Tool`, name
  `<server>_<tool>` (both parts sanitized to `[A-Za-z0-9_-]`, the same
  rule as opencode's `toolName`).
- Server `instructions` → prompt contribution for connected servers.
- Per-server status (`disabled | connecting | connected | failed: <err>`)
  surfaced by the `/mcp` command; failures are non-fatal — a dead server
  contributes nothing, startup continues.
- `enabled = false`, per-server `timeout` (default 30s, per opencode),
  `env` and `cwd` for stdio servers.

**Explicitly out of v1** (follow-ups, same seams):

- OAuth for remote servers (opencode's `auth.ts`/`oauth-*.ts`): v1
  supports static `headers` only; a 401 without credentials reports
  `failed: requires authentication` instead of starting a browser flow.
- Prompts and resources (`listPrompts`, `listResources`) as tools — the
  protocol layer keeps the calls available; no tina tools are generated.
- Sampling/elicitation client capabilities: advertised as absent
  (opencode deliberately keeps them off — see the issue references in
  its `CLIENT_OPTIONS`).
- Hot-adding a new server mid-session: config changes take effect on
  restart, matching the plugin profile rule "startup profile changes take
  effect on restart".
- Live tool-list changes (`tools/list_changed` reshaping a running
  agent's catalog): out of v1 — the engine has no mid-session registry
  rebuild path today (see the manager section). v1 re-lists on
  notification only to refresh `/mcp` output and the status line.
- MCP tools for sub-agents (`toolSetFor` profiles) and restored
  sessions (`toolsFromPolicy`): main-agent-only in v1 (see
  "Sub-agents and restored sessions").

## Configuration

New top-level section in `~/.tina/config` (parsed by
`lib/config/user_config.dart`, which already has the unknown-key warning
machinery — add `mcp` to `_knownTopLevelKeys` plus per-server key
checks):

```toml
[mcp]
default_timeout = 30000        # ms, optional global default

[mcp.github]                   # stdio server
command = "npx"
args = ["-y", "@modelcontextprotocol/server-github"]
env = { GITHUB_TOKEN = "..." } # optional
cwd = "."                      # optional, relative to project root
timeout = 20000                # optional, ms
enabled = true                 # optional, defaults true

[mcp.remote-api]               # remote (Streamable HTTP) server
type = "remote"
url = "https://example.com/mcp"
headers = { Authorization = "Bearer ..." }  # optional
```

- `type` defaults to `local` when `command` is present; `remote` requires
  `url`. A bare `url` with no `command` is remote.
- Types: `McpServerConfig` + `Map<String, McpServerConfig> mcp` on
  `UserConfig`, mapped into `RuntimeConfig` (mirrors how `limits` and
  `permissions` flow).
- Precedence: user config only, like `[permissions]`; no project-local
  mcp table in v1. A project-declared stdio server is arbitrary code
  execution; we do not want that auto-enabled from `.tina/` in an
  untrusted checkout.

## What opencode does (reference notes)

- One MCP service owns a client per configured server; state is
  `{config, status, clients, defs, instructions}` per instance.
- Connect = `acquireUseRelease` over the transport: close the transport
  on failure, hand ownership to the caller on success; 30s default
  timeout; remote tries Streamable HTTP then SSE, and an auth error
  aborts the fallback chain.
- `tools/list` is paginated with a duplicate-cursor guard (max 1000
  pages) and re-run through a tolerant schema (`outputSchema` omitted)
  when validation fails — real servers emit bad schema references.
- Tool conversion: `sanitize(client) + "_" + sanitize(name)`; input
  schema normalized to `type: object`, `properties ?? {}`,
  `additionalProperties: false`.
- `callTool` result: `isError` → throw with text parts joined by
  `\n\n`; empty content + `structuredContent` → JSON-stringified as the
  text content.
- `roots/list` is answered with the working directory as a file URL.
- `logging/message` notifications map to the host logger by level.
- `tools/list_changed` re-lists and re-publishes a ToolsChanged event.
- Teardown: kill the stdio server's process tree (BFS `pgrep -P`), then
  `client.close()`.
- Each *instance* re-connects — opencode composes one MCP service per
  session instance, so same-project runs get separate connections.
  tina matches this: per-conversation connections via a
  conversation-owned plugin (see "Borrowed scopes" under "Failure and
  lifecycle rules").
- Server `instructions` are exposed for prompt context, sorted by name.

## Architecture

### Where the code lives

The protocol and adapter are engine code (no tina_app dependency,
testable with fakes); the plugin descriptor and command live where the
config is resolved (tina_app for `/mcp`, engine for the descriptor,
matching `runtime_plugins.dart` in tina_app for config-dependent
plugins).

```
packages/tina_engine/lib/src/mcp/
  protocol.dart        JSON-RPC 2.0 message model (request/response/notification,
                       id correlation, error codes)
  transport.dart       McpTransport interface + StdioTransport + HttpTransport
  client.dart          McpClient: connect (initialize handshake), request<T>,
                       notification dispatch, close
  catalog.dart         listTools pagination, tool-name sanitization,
                       result-to-ToolResult conversion
  adapter.dart         McpTool: Tool implementation over one (client, def)
  manager.dart         McpManager: per-server state machine, owns clients and
                       process handles, emits changes
packages/tina_engine/lib/src/runtime/mcp_plugin.dart   plugin descriptor
packages/tina_app/lib/src/commands/mcp_command.dart    /mcp
```

### Transports

`McpTransport` — the seam between protocol framing and I/O:

```dart
abstract interface class McpTransport {
  Stream<Map<String, Object?>> get incoming;   // decoded JSON-RPC messages
  Future<void> send(Map<String, Object?> message);
  Future<void> close();
  Stream<void> get closed;                      // peer/process gone
}
```

- **`StdioTransport`**: spawns via the `ProcessRunner` resolved from
  `processRunnerServiceKey` (the same seam bash/grep use, so tests
  inject a fake; the service exposes the PLAIN unsandboxed runner) with
  `workingDirectory` = resolved `cwd`,
  `executable` = the declared `command` (+ `args`), and `environment` =
  merged env. One engine addition: `RunningProcess` today exposes no stdin
  (`process_runner.dart` — stdout/stderr/exitCode/pid/kill only), so the
  interface gains a `StreamSink<List<int>> stdin` member;
  `IoProcessRunner` forwards `dart:io`'s stdin, fakes script it. Reads
  the child's stdout as newline-delimited JSON-RPC (the common stdio
  framing; an LSP-style `Content-Length` header mode is an easy
  extension if a real server needs it — keep the decoder pluggable per
  transport). `close()` kills the process tree (reuse
  `killProcessTree` so a server that spawns descendants doesn't outlive
  the session — opencode does the equivalent with a `pgrep -P` BFS; tina
  already has the tree kill). The server process runs OUTSIDE the
  sandbox: it is user-declared config, and sandboxing it would break
  servers that need real network or file access by design. The guardrail
  is tool-call approval, not the sandbox (see Permissions).
- **`HttpTransport`**: one `POST` per request to the server URL,
  `Accept: application/json, text/event-stream`; a JSON body is the
  response; an SSE body is consumed until the event completes the
  request. Honors `Mcp-Session-Id` from the initialize response on all
  subsequent requests. A `GET` stream for server-initiated messages is
  not required in v1 (we don't advertise sampling/elicitation, so the
  server has little reason to push mid-turn).

### Client

`McpClient.connect()` performs the `initialize` handshake (protocol
version 2025-06-04, capabilities: `roots` only), then sends
`notifications/initialized`. Every request gets a per-request timeout
(`TimeoutException` → surfaced as a tool error; opencode's
`resetTimeoutOnProgress` is out of v1 — a plain timeout is honest).
Cancellation: a canceled tool call sends `notifications/cancelled`
(method `tools/call`, our id) — best effort; we still await the real
response so the transcript stays paired.

### Manager and plugin

`mcpPlugin(Map<String, McpServerConfig> servers, {required String
projectRoot})` — one `PluginDescriptor`, id `tina.engine.mcp`:

- `requires`: the new `processRunnerServiceKey` (stdio spawning;
  remote uses `dart:io` HttpClient) — provided by the capabilities
  stage, which already owns process construction for the tools. The
  service exposes the PLAIN runner (`IoProcessRunner` or equivalent
  unsandboxed implementation), never the sandboxed variant: servers
  run outside the sandbox by design (see Transports). When `servers`
  is empty the factory is a no-op, which keeps every mcp-free session
  byte-identical to today (the profile rule: extensions must not
  change the default composition when unconfigured).
- **Connect is async; factories are sync.** The factory starts every
  enabled server's connect immediately, collects the futures, and
  provides `mcpReadyServiceKey` (`Future<void>`);
  `buildExecutionRuntime` — which already `await runtime.activate()` —
  additionally awaits the ready future after activation (skipped when
  the service is absent), bounded by the connect timeout.
  Activation order and rollback are untouched; only pipeline assembly
  is delayed by at most the connect timeout. A failed server completes
  with a status, never throws past the manager, so startup is never
  blocked.
- `context.own`s a cleanup that (1) awaits still-pending connects with a
  hard ceiling (the connect timeout), (2) closes each client, (3) kills
  each stdio process tree — in reverse acquisition order, per the
  runtime's teardown contract.
- Once connected: for every tool def of every connected server,
  `context.register(McpTool(...), id: mcpToolName(server, def))` into
  the execution runtime's scope. MCP tools are not in
  `kProjectToolCatalog`, so at assembly they sort after the frozen
  catalog in registration order, exactly like `web_search` does today.
  **How those tools reach the agent's registry — and the two-scope
  trap — is the next section.**
- Name collisions (with built-ins, and across servers) are handled at
  the merge in the next section: warn naming both the MCP tool and the
  incumbent, skip the MCP tool, continue. A user's config mistake must
  not crash composition.
- `provides`: `mcpServiceKey` (the `McpManager`) — consumed by `/mcp`
  and the prompt contributor; `mcpReadyServiceKey` (the connect future).
- **`tools/list_changed` (protocol support, registration NOT)**: v1
  re-lists on notification only to refresh `/mcp` listings and the
  status line — the registered tool set is frozen at startup. Today's
  engine has no path from a mid-session scope change to a live agent:
  `ToolRegistry.forStep()` returns `this` (tool.dart), and the agent's
  registry list is fixed at conversation construction. Live catalog
  swap needs per-step (or `scope.changes`-driven) registry rebuilding —
  its own milestone, not a free consequence of the freeze contract
  ("Cache and persistence invariants" in plugin_runtime.md constrains
  stability per composed catalog; it does not provide the swap).
- **Process died mid-session**: `transport.closed` → manager marks the
  server `failed: connection closed`, revokes its tool registrations,
  emits a host notice. No reconnect in v1 (opencode doesn't either).
  (The revocation keeps `/mcp` truthful; per the `tools/list_changed`
  bullet above, a mid-session change does not re-shape a live agent's
  tool list.)

### Wiring: where the tools actually land

There are TWO plugin runtimes in play:

1. the execution runtime `buildExecutionRuntime` composes (profile:
   ledger, factory, capabilities, tool-scope stage, ...), and
2. the `PluginRuntime` inside `ProjectToolScope` itself
   (`project_tool_scope.dart`), which `buildTools()` — and therefore
   the main agent's registry, via `pipeline.tools.buildTools().all` in
   `agent_composition.dart` — actually reads.

Mounting `mcpPlugin` on the execution runtime registers tools into a
scope that tool assembly never reads — the M4 no-config test would
pass vacuously. v1 closes the gap with a **registry merge**:

- **The plugin mounts on the execution runtime** (conversation-owned),
  after the tool-scope stage in `defaultExecutionPlugins` (its
  `requires: processRunnerServiceKey` forces that anyway — the
  capabilities stage provides it). When `servers` is empty the plugin
  is simply not mounted; mcp-free sessions keep the default
  composition untouched.
- **The merge (the engine addition):** `buildAgent`'s base list,
  `pipeline.tools.buildTools(...).all` in `agent_composition.dart`,
  gains the execution scope's MCP contributions appended after the
  base tools (same sorting rule: after the frozen catalog, in
  registration order — exactly the position `web_search` occupies
  today). One place, one line of call-site change; the catalog itself
  and `toolRegistryFromScope` are untouched.
- **Collision rule at the merge:** if an MCP name equals a built-in
  (or another MCP name from a different server), warn naming both the
  MCP tool and the incumbent, skip the MCP tool, continue — a config
  mistake must not crash composition.
- **Per-conversation connections:** the plugin is conversation-owned,
  so each conversation (or same-project runtime) that mounts it gets
  its OWN set of server connections and its own manager instance —
  two agents in one project spawn two copies of each stdio server,
  matching opencode's per-instance re-connect. The borrowed-scope rule
  follows: a borrowing runtime keeps the plugin in its list (it is not
  in `_projectOwnedPluginIds`), so borrowers connect independently —
  the owner's disposal does not affect them.
- The connect-await: `buildExecutionRuntime` awaits the plugin's
  `mcpReadyServiceKey` after `activate()`, bounded by the connect
  timeout — connections are established before the first turn, and one
  dead server delays startup by at most its own timeout while the rest
  proceed.

### Sub-agents and restored sessions (v1 scope decision)

MCP tools are MAIN-AGENT-ONLY in v1. `toolSetFor(profile)` and
`toolsFromPolicy(...)` assemble from fixed name lists
(`project_tool_scope.dart`), so sub-agents (any profile) and restored
sessions never see MCP tools. Since sub-agents inherit the main
agent's resolved system prompt — which lists the MCP tools — the
prompt contribution must qualify this explicitly, e.g. a final line
"these tools are not available to sub-agents you delegate to; call
them yourself." Extending profiles/restore to MCP tools is follow-up
work (same seams, needs a policy for which servers a `read-only`
sub-agent may call).

### The tool adapter (`McpTool`)

```
name:        sanitize(server) + "_" + sanitize(tool.name)
description: "[mcp:server] " + (def.description ?? def.name)
inputSchema: def.inputSchema (normalized: type=object, properties ?? {},
             additionalProperties=false — opencode's convertTool rule;
             guards against servers that emit `type: ["object","null"]`)
execute:     client.callTool(name, arguments) with the server's timeout
             + cancelSignal (sends notifications/cancelled on fire)
```

Result conversion (opencode parity):

- `isError: true` → `ToolResult.isError` with the text parts joined by
  `\n\n` (or `"MCP tool returned an error"` when empty).
- Content parts: `text` → verbatim; `image` → one line
  `[image <mime>, N bytes]` (v1 does not feed images to the model);
  `resource` (inline) → `[resource <uri>] <text>` when it carries text.
- Empty content + `structuredContent` present → JSON.stringify of the
  structured content (opencode's exact fallback).
- `elapsed` is populated (wall-clock of the call) so the tool strip
  shows timing like `bash`.

### Permissions and safe mode

- New tool names are ordinary names: the base policy's default for
  unknown tools is `ask`, so every MCP tool call prompts by default —
  the right posture, since an MCP server's `tools/call` is arbitrary
  external execution. `--yolo` allows them; static rules target them
  like any tool: `--allow 'github_get_repo:*'`.
- The existing inert-rule warning (agent_composition.dart: "rule names a
  tool that is not available") automatically covers MCP names.
- `--safe-mode`: MCP tools are NOT stripped — they are the user's
  explicit configuration, and safe-mode's contract is "no shell/file
  mutation", which an MCP tool neither is nor guarantees. If that
  changes the contract, one line in `stripForSafeMode` does it; not in
  v1.
- The **server process** is spawned outside the sandbox (see
  Transports); its **tools** go through the normal approval flow. This
  split is documented, not accidental.

### Prompt contribution

A `PromptContributor` (profile-mounted, per plugin_runtime.md's prompt
contract) renders, for connected servers with `instructions`:

```
## MCP servers
### github
<server instructions>
Available tools: github_get_repo, github_list_issues, ...
(These tools are yours only: not granted to sub-agents you delegate to.)
```

Ordered after built-in blocks, so it never rewrites the stable prefix.
No connected servers → contributes nothing (byte-identical prompts).
The resolved prompt is fixed at conversation construction, so it lists
the startup tool set; a mid-session `tools/list_changed` does not
rewrite it (only `/mcp` output refreshes).

### `/mcp` command

Registered through `CommandRegistry` (the command_plugins mechanism):

- `/mcp` — one line per configured server:
  `github            connected   12 tools`
  `flaky-remote      failed      connect timeout after 30s`
  `disabled-one      disabled`
- `/mcp <server>` — tool list with one-line descriptions.

Reads `mcpServiceKey` from the composition's plugin scope; when no MCP
config exists the command reports "no MCP servers configured" (kept
registered always so help output is stable; cheap).

## Failure and lifecycle rules (from the plugin runtime contract)

- **No partial state**: a server that fails `initialize` owns nothing —
  its process (if any) is killed in the connect error path, status is
  `failed`, and it never enters the registry.
- **Teardown order**: scope dispose drains contributions (revoking tool
  registrations) then resources (the manager cleanup) — clients close,
  then process trees kill, in reverse acquisition order. A late
  `tools/call` response after close is dropped, not surfaced.
- **Borrowed scopes**: a runtime borrowing a same-project tool scope
  (`borrowedScopePlugins`) keeps the MCP plugin in its list (it is
  conversation-owned, not in `_projectOwnedPluginIds`) — so borrowers
  connect their OWN servers (per-conversation connections, matching
  opencode's per-instance re-connect); the owner's disposal does not
  affect them. Trade-off accepted: two same-project agents run two
  copies of each stdio server (duplicate processes/logins) in exchange
  for full isolation. ("Same project" = same normalized root
  directory: one shared toolbox and write lock per directory per
  process, created by the first runtime that needs it and disposed by
  its owner — see `ProjectToolScope`.)
- **No global state**: the manager is the single owner of clients; there
  is no process-wide registry (opencode's module-level
  `pendingOAuthTransports` is an anti-pattern we do not import).

## Implementation sequence

Each phase is a separate reviewable change (repo convention).

| Phase | Work | Completion evidence |
| --- | --- | --- |
| M0: config | `McpServerConfig` in `user_config.dart` + parse/warn/round-trip; `RuntimeConfig.mcp` | config parse tests incl. unknown-key warnings, bad type, missing url/command |
| M1: protocol + transports | `protocol.dart`, `transport.dart`, `StdioTransport`, `HttpTransport` (engine); `RunningProcess.stdin` addition | golden JSON-RPC tests against a scripted in-process stdio server (fake `ProcessRunner` + pipes) and a fake HTTP endpoint; framing edge cases (partial lines, oversized frames, session id); stdin write path exercised through the fake |
| M1.5: merge seam | `buildAgent`'s base list gains the execution scope's MCP tool contributions (merge + collision warn-and-skip); `processRunnerServiceKey` published by the capabilities stage | baseline case: registry contents and order byte-identical to today; a synthetic MCP contribution in the execution scope appears after `web_search`, colliding names warn and skip |
| M2: client + catalog | `client.dart`, `catalog.dart` (pagination, lenient outputSchema retry, sanitization) | handshake happy path; timeout; pagination across 3 cursors; duplicate-cursor guard; list failure → status failed, no throw |
| M3: adapter + manager | `adapter.dart`, `manager.dart`; status machine; process-death handling | cancel → `notifications/cancelled` sent; isError mapping; image/resource fallbacks; dead stdio server revokes its tools and notifies |
| M4: plugin + wiring | `mcpPlugin` mounted in `defaultExecutionPlugins` after the tool-scope stage; `mcpReadyServiceKey`; `buildExecutionRuntime` awaits ready (bounded); `/mcp` command registered always | **positive test: one configured stdio server → its tools present in the main agent's registry**, not just "no-config = no change"; no-config session: zero MCP tools, zero behavior change; one failing server: startup proceeds, warning shown; two same-project runtimes: independent managers and server processes |
| M4.5: prompt + status | prompt contributor (with the sub-agent caveat line), startup log lines, `/mcp` tool listings refresh on `tools/list_changed` | prompt golden test with/without instructions; `/mcp` output for each status; list_changed refreshes `/mcp` only |
| M5: docs + hardening | `docs/features/mcp.md`, architecture ratchet | `dart analyze` clean in both packages, `dart tool/check_architecture.dart` passes (engine mcp/ imports only engine deps) |

M4 is the first user-visible milestone; it ships stdio-only if the
remote transport tests are not green (transport selection is per-server,
so a remote config degrades to `failed` with a clear message rather
than blocking startup).

Live catalog swap (`tools/list_changed` → registry rebuild, mid-session)
is deliberately NOT a milestone here — see the manager section; it needs
per-step or `scope.changes`-driven registry rebuilding, which is
follow-up work with its own tests (prompt staleness, permission rules
for late-arriving names, sub-agent inheritance).

## Open questions (decide at M4)

1. ~~Remote without OAuth~~ — decided: no OAuth in v1, no `mcp auth`
   command. Static `headers` only; a 401 without credentials reports
   `failed: requires authentication`. Revisit only if remote servers in
   real use demand it.
2. ~~`tools/list_changed` → live catalog swap vs. next-step swap~~ —
   resolved by review: neither is available today (`forStep()` is a
   no-op returning `this`; the agent's registry is fixed at
   conversation construction). v1 freezes the registered set at
   startup; live swap is follow-up work.
3. ~~Max concurrent connects~~ — decided: unbounded (opencode parity).
   Every enabled server starts connecting at once; a config with 50
   servers forks 50 processes at startup — accepted.
4. ~~Borrowed-scope MCP sharing~~ — decided: per-conversation
   connections (opencode parity). Each conversation/runtine that
   mounts the plugin spawns its own server copies; borrowers are
   unaffected by the owner's disposal. Trade-off accepted: duplicate
   processes per same-project agent.
5. ~~Process-runner provenance for stdio servers~~ — decided: a
   looked-up plugin service (`processRunnerServiceKey`, provided by
   the capabilities stage, PLAIN unsandboxed runner). Rationale:
   uniform provenance with future metered/limited spawn support;
   `requires`-edge also pins the plugin after the capabilities stage
   in the profile.
