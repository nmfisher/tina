# tina/mcp

MCP client plugin for engine2. See [configuration and Blender setup](../../../docs/engine2-mcp.md).

Protocol, connections and conversation grants live here. The application injects
an approval capability; `McpConsolePlugin` in `tina_tui` attaches settings through
`ConsoleContribution`. Neither the loop nor the host knows about MCP.

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
