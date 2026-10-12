# tina_mcp_tui

Independent MCP settings views over the session-owned `tina_mcp` feature.

`McpView` implements `ConsoleContribution` and receives `McpManagement` from a
configured `McpPlugin`. The application creates a fresh view for each attachment.
The view registers its own settings section and subscribes to configuration and
status changes; detaching releases both without closing a server or clearing
session approvals. Status actions write to the invoking view's chat region.

The runtime owns configuration validation, storage, connection lifecycle,
discovery, execution and grants. Editors merge field changes with the current
saved configuration, retain the existing global scope and next-turn application,
and mask environment/header values in their menus. Notifications carry no values.

Run `dart test` for settings tests and a real subprocess test covering two views,
detachment during an active call, retained approvals and next-turn disabling.
