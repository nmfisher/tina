# Command plugins

Slash commands are plugin contributions. Both the interactive frontend and
headless `--prompt` dispatch through `CommandRegistry`, exported by `tina_app`.
The registry also supplies help and completion names, so adding or removing a
contribution updates all three surfaces together.

Register a command in an application plugin passed to
`buildAppComposition(plugins: [...])`:

```dart
PluginDescriptor(
  id: 'hello',
  factory: FnPluginFactory((context) {
    context.register(
      Command(
        names: ['/hello', '/hi'],
        argsHint: '[name]',
        summary: 'say hello',
        handler: (call) async {
          call.write('Hello ${call.arguments}!\n');
          return const CmdHandled();
        },
      ),
      id: 'hello.command',
    );
    return Object();
  }),
);
```

`CommandCall` contains the original command line, parsed word and arguments,
conversation ID, output method, and cancellation signal/state. The host pins
output to the originating conversation. Plugins obtain other services through
their declared dependencies in the existing plugin runtime.

Handlers return `CmdHandled`, `CmdExit`, or `CmdRun(prompt)`. `CmdRun` submits a
normal user turn through the [input routing pipeline](input_routing.md), which
can later include a classifier router. Ordinary text returns `CmdNotCommand`.
Unknown slash commands and handler errors are reported as failed commands.

Each frontend mounts its built-ins in a child plugin scope. The interactive
frontend mounts the existing session commands; headless mode mounts `/help` and
`/index`. Both inherit application command contributions from their parent
scope. Closing the frontend scope does not dispose its borrowed parent.
The legacy static session-command catalog remains for compatibility; live
dispatch, help and interactive completion use the scoped registry.

Names and aliases must be unique across the visible scope and its parents.
Collisions are errors, including names on commands hidden by feature settings.
A registry's `hiddenFeatures` filters dispatch, help and completion together.
Help shows the primary name and sorts by `helpOrder`; completion includes aliases.

Interactive double-Esc and headless Ctrl+C interrupt command waits. Plugins must
observe `call.cancelSignal` to stop their own work. Writes after cancellation or
completion are ignored, and late results cannot start an agent turn. Revoking
a contribution prevents subsequent dispatches and discards its pending result.
