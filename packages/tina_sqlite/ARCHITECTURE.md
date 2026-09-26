# tina_engine

The agent core: runs turns, calls models, executes tools, checks
permissions, records sessions. No terminal dependency, no root-package
dependency — the TUI and the headless runner are both consumers, so
`--prompt` runs and sub-agents use the same loop as the interactive TUI.

**Baked in vs pluggable.** "Baked in" means compiled into the binary and
always mounted. The engine's baked-in surface: the agent loop (`agent/`);
the permission precedence (session rules → static rules → capability
defaults → asker); the provider registry and wire adapters (`llm/`); the
built-in tools (`tools/` — registered through the plugin scope so they
can be staged, but compiled in); the sandbox; and the plugin runtime
itself (`runtime/`).

Persistence is the seam case: **the store is a plugin, the format is
core.** The `SessionStore` interface, the JSONL format, the per-session
layout under `~/.tina/sessions/`, locks, and index are all compiled in;
`jsonlSessionStorePlugin` only binds an instance under
`sessionStoreServiceKey` at activation. Consumers resolve the store only
through that key, so an alternative backend is a different plugin on the
same key — config selects it with `[sessions] provider` (one id ships
today), and consumers never learn the difference.

## Layout

```
lib/
  tina_engine.dart      public barrel — the only supported import surface
  src/
    agent/              the tool-calling loop and its satellites
    llm/                message model, providers, wire adapters, registry
    tools/              Tool interface, built-in tools, sandboxing
    permissions/        policy, asker, classifier, previews
    persistence/        session store (JSONL) + session-store plugin
    runtime/            the plugin runtime every extension point uses
    skills/             file-based skills
    terminal/           PTY transport for the `bash_pty` tool
    host/               HostInterface: headless + interactive host seams
    platform/           platform-dependent paths
```

## Agent loop

`Agent.run()` is one loop:

1. Rebuild the system prompt (`system_prompt.dart`: workspace summary,
   skills, plan/goal state).
2. Stream from the provider into a `StreamConsumer`.
3. If the model asked for tool calls, run them through `ToolExecutor` —
   registry → `PermissionPolicy` → guard hooks → execute → record — and
   append the results. Otherwise append the text and end the turn.

Backstops: `maxSteps`, a hard ceiling on tool uses per turn, and
`token_budget.dart` (drops or summarizes the oldest blocks). The spend
ledger caps total model spend; crossing it surfaces as a `StreamError` and
stops the turn through the normal error path.

Satellites: `sub_agent_scheduler.dart` (child agents with their own tools
and policy), `pause_gate.dart` (pause/resume), `agent_middleware.dart` +
`agent_pipeline.dart` (turn hooks — plan and goal middlewares plug in
here), `tool_hooks/tool_guards/tool_checks.dart` (pre-execution layers),
`stream_consumer.dart` + sinks (UIs see events, not the loop).

## Plugin runtime (`runtime/`)

- `plugin.dart` — `PluginDescriptor` (id + factory); lifecycle
  `start/ready/stop/fail`.
- `runtime.dart` — `PluginRuntime`: activation in id order, `requireX`
  lookups, parent/child scopes, contributions, reverse-order dispose. A
  monotonic activation token stops stale async activation after dispose.
- `contracts.dart` — `ServiceKey<T>`, `PluginContext` (register / require /
  contribute / own), `Contribution<T>`.

Ids are lowercase and dot-namespaced; `tina.*` is reserved for built-ins.
Id order is activation order, which is how an earlier id wraps a later one.

## Model access (`llm/`)

`message.dart` is the transcript model. `provider.dart` defines
`LlmProvider` and the `StreamEvent` hierarchy. Wire adapters: `anthropic`,
`gemini`, `openai`, `openai_compatible` (most third-party endpoints), over
`sse.dart` / `http.dart`. `registry.dart` holds compiled descriptors
(anthropic, openai, gemini, openrouter, groq, glm, qwen, qwencloud,
deepseek, mistral, cerebras, grok, hetzner, longcat, nim, novita, tencent)
plus config-declared and models.dev-seeded providers. Decorators:
retry, key pooling, metering (feeds the spend ledger), rate limiting,
HTTP logging. `model_catalog.dart` feeds the model picker.

## Tools and sandbox

`Tool` is small: a schema and `execute(input, {cancelSignal, onOutput})`.
`LocalControlTool` marks orchestration-only tools so they skip approval.
`ToolRegistry` is last-wins by name, so composition helpers append onto a
base registry to extend or override.

Built-ins: `read`, `write`, `edit`, `glob`, `grep`, `ls`, `stat`, `bash`
(sandboxed by default), `exec`, `process`, `git`, `fetch`, `web_search`,
`delegate`, `render_image`, `write_summary`, `which`, `execution_info`,
channel tools (mid-turn user interaction), `bash_pty` (worker-isolate PTY).

`sandbox.dart` runs commands under a writable-path working set;
`sandbox_failure.dart` classifies refusals so the model can retry with an
approval request. `atomic_write.dart` and `mutation_lock.dart` serialize
file mutations. `workspace_tool_plugins.dart` is the seam where the app
layer contributes tools as plugins.

## Permissions

Decision order for one tool call:

1. Session rules (this session's approvals, persisted per project).
2. Static rules (`--allow` / config / skills).
3. The tool's declared capability defaults.
4. The asker (`mode_aware_asker.dart`): "auto" consults the classifier —
   a one-shot model call; any failure falls back to asking a human, never
   to running the call. Read-only mode declines non-read-only calls.

`preview.dart` builds approval-card previews; `regex_suggester.dart`
suggests rules from denied calls; `sandbox_access.dart` bridges approvals
into the sandbox's writable set.

## Sessions (`persistence/`)

`session_store.dart` is the interface (manifests, transcripts, roles).
`jsonl_session_store.dart` is the default: one directory per session under
`~/.tina/sessions/`. `session_lock.dart` is a PID-liveness lock.
`session_store_plugin.dart` mounts the store as a plugin, so an alternative
backend can be contributed before consumers resolve it.

`skills/` loads skill files into their own plugin scope (dispose revokes).
`host/` defines `HostInterface` — headless host plus the shape the TUI
implements — and `history_replay.dart` rebuilds a conversation on resume.

Engine tests live in this package's `test/`; no UI involved.
