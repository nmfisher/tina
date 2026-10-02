# Plugin UI contributions

UI plugins implement `ConsoleContribution` from `tina_console` alongside
`AgentPlugin`. The TUI detects the interface at startup and through the plugin
manager's live load/unload callbacks. No engine-loop hooks are involved.

Each attachment receives its own `ConsoleContext` scope. Registration methods
track their cleanup automatically. The TUI disposes that scope on unload,
shutdown, or failed attachment, even if `detachConsole()` throws. A disposed
scope rejects new registrations. Plugins must register resources through the
context to receive this guarantee; direct screen/editor mutations are not tracked.

## Settings sections

```dart
class ExampleUi extends AgentPlugin implements ConsoleContribution {
  @override
  String get id => 'acme/example-ui';

  bool showDetails = false;

  @override
  void attachConsole(ConsoleContext context) {
    context.settings.registerSection(
      id: 'acme/example-ui',
      title: 'Example',
      order: 100,
      build: () => [
        SettingToggle(
          id: 'show-details',
          label: 'Show details',
          read: () => showDetails,
          change: (value) => showDetails = value,
        ),
      ],
    );
  }

  @override
  void repaintConsole() {}

  @override
  void detachConsole() {}
}
```

Sections appear in `/settings` for the current session. Section IDs are
namespaced and unique within that session; ordering uses `order`, then ID.
Control IDs must be unique and stable within a section. Separate conversation
panels have separate registries, so the same plugin can contribute to each.

Supported controls are `SettingToggle`, `SettingText` (including masked text),
`SettingChoice`, and `SettingAction`. Read/build callbacks describe the current
UI; change/action callbacks may return a future. Callbacks run when the user
accepts a field or activates a control. The plugin owns the behavior of those
callbacks. These controls have no config schema, storage path, or automatic
connection to the built-in settings Save action.

Registration and removal notify an open settings panel. It preserves selection
by control ID and returns to the main menu if the current section disappears.
An unloaded section's pending text editor cannot invoke its change callback.
An already started async callback is not forcibly cancelled. Call
`context.settings.refresh()` when external state changes the controls or values.

`registerSection` returns an idempotent removal callback for early removal;
calling it yourself is optional because the attachment also owns it. To replace
a section, remove the existing registration before registering its ID again.

## Other contribution points and resources

`bindPrompt`, `bindStatus`, `bindShortcut`, and `addModal` follow the same ownership
rules. Settings has its own typed registry because its entries differ from
status lines and keyboard handlers. Future panels can expose their own typed
registries through `ConsoleContext` using this same lifecycle.

For resources such as an overlay or timer, use `context.own(overlay.hide)` or
`context.own(timer.cancel)`. The returned callback releases the resource once;
otherwise it is released automatically in reverse registration order.

`context.interact(action)` serializes an interaction with other dialogs and
hides the conversation cursor until the action finishes. A custom interactive
overlay can use `screen.claimCursor()` and register its `release` callback with
`context.own`. The claim starts hidden; `place(row, col)` shows the caret in an
editable field, and `hide()` hides it when returning to choices. Claims nest:
the newest owner controls the cursor, including during background output and
resizing. Releasing it restores the previous owner or the conversation draft.
Completion suggestions keep the conversation cursor because they still edit
that draft.

Live loading still follows the plugin registry's policy: only definitions marked
`live` load/unload without restarting, and changes are applied between turns.
The UI only exposes contributions from loaded plugins.
