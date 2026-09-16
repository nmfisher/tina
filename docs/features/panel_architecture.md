# Panel content and input ownership

`PanelHost` opens arbitrary `PanelContent` using a `PanelSpec` with a stable ID,
label, and placement. It owns the frame, registration, and view cleanup. It does
not construct a conversation, transcript, workflow, shell, or subprocess.

`RunPanelHost` adapts workflows to that host. It creates the transcript and sink,
installs the sink synchronously before streaming can begin, and implements the
workflow's stop/close keys and scrollback. Closing a workflow view still leaves
the run alive unless the caller explicitly stops it.

The application supplies content binding and layout callbacks. The existing
`ConversationPanelCoordinator` fits and parks extra content in both tiled and
sidebar layouts, alongside its conversation bindings. `PanelManager` continues
to own geometry and the focus ring. Its frame IDs retain the legacy
`conversationId` field name internally; custom panel IDs need no corresponding
conversation in the session.

## Input contract

`PanelInputTarget` is an optional focusable capability, implemented by
`PanelFrame`. Its `PanelInputMode` determines routing:

| Mode | Behavior |
| --- | --- |
| `sharedEditor` | Conversation panels allow unhandled keys to reach the shared chat editor. These require a conversation binding. |
| `readOnly` | Custom panel commands and scrollback run normally; unhandled text input is consumed. App navigation and interrupt behavior remain available. |
| `exclusive` | The focused panel receives semantic input events before chat editing, cancellation, or app shortcuts. Unhandled events are dropped. Ctrl+G is reserved for focus cycling. |

An exclusive panel receives Ctrl+C, Ctrl+D, Ctrl+W, Escape, arrows, Tab, paste,
and other keys. During Ctrl+G cycling, the focus manager owns navigation until
Enter commits or Escape cancels. Prompts and modal overlays take priority over
the panel; approval answer keys and character overflow cannot spill into it.

The shared editor is hidden when exclusive content is focused, including after
resize. Its draft and cursor position survive a return to the conversation.
Closing a focused panel restores focus to the primary panel.

## Lifecycle and testing

Opening is synchronous and does not steal focus. Duplicate IDs are rejected
before registration. Failed registration rolls back the view. Closing is
idempotent and checks handle identity so an old handle cannot close a replacement
with the same ID. `onDispose` releases view subscriptions once; the owner of a
backing process or job remains responsible for its asynchronous shutdown.

Tests cover generic content without agent/session fixtures in
`test/tui/panel_host_test.dart`, workflow behavior in `run_panel_host_test.dart`,
and draft/resize behavior in `conversation_panel_coordinator_test.dart`.
`packages/tina_console/test/panel_input_test.dart` exercises exclusive ownership,
prompt priority, cancellation, paste, and focus navigation.

This is the UI foundation for an interactive terminal panel. The headless
[PTY backend](pty_backend.md) shipped in v0.6.30. The remaining emulator,
input encoding, rendering, and command integration are specified in the
[terminal implementation plan](terminal_panel_plan.md).
