# MCP servers

`tina/mcp` is a first-party plugin. It is enabled in the default plugin selection
and does nothing until servers are configured. If your config has an explicit
`[plugins].enabled` list, enable it in **Settings → Plugins**. That checkbox
supports Global, Workspace and Session scope like other plugins.

Use **Settings → MCP servers** to add a local or HTTP server, set its command/URL
and arguments, and enable it. New entries start disabled. Server settings are
global, stored in the selected `~/.tina/config` (or `--config` file). They save
immediately; connections and discovery reflect changes on the next message.
Unloading `tina/mcp` closes its connections and removes its settings attachment.

## Official Blender Lab server

Follow [Blender Lab's official setup](https://www.blender.org/lab/mcp-server/)
to install its add-on and MCP server. The official source is
[`lab/blender_mcp`](https://projects.blender.org/lab/blender_mcp).
This integration targets that server, not the separate ahujasid project.

With Blender open and the add-on running, configure the installed server:

```toml
[mcp.servers.blender]
command = "/absolute/path/to/blender-mcp"
args = ["--transport", "stdio"]
enabled = true
timeout_ms = 120000
env = { BLENDER_MCP_HOST = "localhost", BLENDER_MCP_PORT = "9876" }
```

Use the add-on's configured host/port. For the official server's background
Blender tools, set `BLENDER_PATH` in `env` to the Blender executable if needed.
Local MCP commands launch directly, without a shell, with your account's
privileges and inherited environment. Configure commands you trust. Their tool
calls still go through Tina's permission mode and approval channel.

Ask about the scene or request an edit. Tina advertises the discovered schemas
to the model and displays tool calls with the server's name and readable fields.
Screenshot tool results are passed as images to Anthropic, OpenAI-compatible and
Gemini providers, and saved in the transcript. A model with image support is
needed to interpret them; the terminal displays an image label.

## HTTP and credentials

```toml
[mcp.servers.remote]
url = "https://your-server.example/mcp"
headers = { Authorization = "Bearer ${MY_MCP_TOKEN}" }
enabled = true
timeout_ms = 60000
```

`${VARIABLE}` expands from Tina's environment in command, arguments, env values,
URL and headers. A missing variable prevents connection; values are not expanded
back into the config. Environment/header fields are masked in settings. HTTP
redirects are not followed and failed tool calls are never replayed automatically.

## Consumed configuration

Only `[mcp.servers.<name>]` tables are supported. Unknown MCP keys are rejected.

| Key | Meaning |
| --- | --- |
| `command` | Executable for a stdio server; mutually exclusive with `url` |
| `args` | String array, default `[]`; stdio only |
| `cwd` | Directory relative to the workspace, or absolute; default workspace; stdio only |
| `env` | String map overriding the inherited environment; stdio only |
| `url` | HTTP(S) Streamable HTTP endpoint; mutually exclusive with process settings |
| `headers` | String map of HTTP headers; protocol/session headers are reserved |
| `enabled` | Boolean, default `true` in hand-written config |
| `timeout_ms` | Per protocol request, default `60000`; `0` disables the timeout |

The timeout starts when a protocol request is sent, after approval. Approval
dialogs have no timeout by default. Cancellation sends `notifications/cancelled`;
the external operation may already have taken effect. Inspect application state
before retrying a cancelled/timed-out edit.

## Approval and lifecycle

Ask, read-only and allow-edits modes ask for MCP calls. Server annotations are
not trusted as permission grants. Auto mode uses the existing structured safety
classifier, falling back to human approval when it cannot approve the operation.
Always allow covers the exact server configuration, method, tool and arguments
for this conversation. A different call asks again. Grants are not persisted or
restored on resume, and reconnecting/reconfiguring/unloading drops them.

Schema names include server identity and a stable suffix to avoid collisions
and fit provider tool-name limits. Tool-list notifications take effect on the
next turn. An unavailable server is reported and omitted, while ordinary chat
and other tools remain available. Servers close on plugin unload/session exit.

## Supported surface and limits

Supported: stdio, stateful Streamable HTTP with JSON/SSE responses, initialize/
initialized, paginated tool discovery, tool calls, changed-tool notifications,
ping, workspace roots, cancellation and shutdown. Resource lists/templates/read
and prompt lists/get are exposed as server-specific tools when advertised.
Tool text, structured JSON, image results and embedded text/resource links are
preserved. Binary audio results are explicitly reported as unsupported.

Negotiated protocol revisions: `2025-11-25`, `2025-06-18`, `2025-03-26`,
`2024-11-05` (stdio). Legacy separate SSE endpoints, OAuth login, MCPB bundle
installation, server sampling/elicitation, task-augmented execution and resumable
HTTP event streams are not implemented. Unsupported client methods return a
JSON-RPC error; capabilities are not advertised for them.

Verification covers a real subprocess fixture, local HTTP/SSE server, provider
image encoding, session replay, permission modes, exact remembered grants,
cancellation, timeouts, disconnects, config saves and dynamic plugin lifecycle.
Blender Lab's actual server was also tested for initialization, discovery and
API-documentation retrieval. Real scene edits and screenshots still require a
running Blender instance for the final end-to-end check.
