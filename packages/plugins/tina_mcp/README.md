# tina/mcp

MCP client plugin for engine2. See [configuration and Blender setup](../../../docs/engine2-mcp.md).

Protocol, connections and conversation grants live here. The application injects
an approval capability. `McpPlugin.configured` also owns the `McpConfigStore`;
its `McpManagement` capability exposes configuration reads, field edits and live
status to independent `McpView` attachments in `tina_mcp_tui`. Each view owns its
settings registration and subscription. Detaching one leaves connections, active
calls, discovered tools and exact session grants intact. Neither the loop nor
the host knows about MCP.

Configuration stays global and applies on the next turn. Field edits merge into
the latest saved server instead of overwriting another editor's changes. Invalid
edits leave the file intact. Change notifications carry no configuration values;
environment and header fields remain explicit secret editors. The original
`McpPlugin(readServers: ...)` constructor remains available for standalone
callers without persisted settings.

Tools are discovered in the generic `prepareTurn` hook before schemas are pinned.
Notifications mark discovery dirty for the next turn. Executors register with
the plugin's ownership scope, so dynamic unloading removes them and closes servers.

Run `dart test` for actual subprocess/HTTP integration tests. For the optional
official Blender Lab interoperability check:

```sh
TINA_MCP_BLENDER_COMMAND=/absolute/path/to/blender-mcp dart test test/official_blender_test.dart
```

The optional test initializes the real server, discovers its schemas and retrieves
bundled Python API documentation. Scene edits/screenshots need Blender's running add-on.
