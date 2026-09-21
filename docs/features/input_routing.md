# Input routing plugins

The application can route a user message before compaction or agent execution.
No routers are installed by default, and there is no classifier router yet.

The input path is:

```text
command handling → conversation queue → input routers → selected handler
                                                     → current agent (fallback)
```

TUI input and headless `--prompt` use the same `InputRoutes` service.
[Command plugins](command_plugins.md) handle slash commands first. Built-in
commands such as `/index` keep their command path. A command that expands into an
agent prompt enters the normal input path. Internal workflow completion messages
bypass routers, including when queued. Delegated agents and individual model/tool
calls do not go through this user-input extension point.

## Contracts

All types are exported by `package:tina_app/tina_app.dart`:

- `InputContext`: original text, conversation ID, a detached history snapshot,
  cancellation signal and cancellation state. It exposes no live conversation,
  driver, host or mutable queue.
- `InputRouter.route(context)`: asynchronously returns an `InputRoute` or null.
- `InputRoute`: the handler's contribution ID and optional JSON data. A future
  classifier router can pass labels here without changing the user's text.
- `InputHandler.handle(context, route)`: asynchronously returns a text reply.
- `InputRoutes`: reads live contributions from the existing plugin scope and
  manages routing, reply presentation and transcript persistence.

Routers run in contribution registration order. The first non-null route wins.
When all routers return null, the current conversation agent receives the input
through its existing driver. Plugin activation follows the runtime's dependency
order; declare dependencies when router registration order matters.

An unknown handler, plugin failure, removal during execution, or timeout fails
that turn visibly; it does not silently send the message to the default model.

## Registering a plugin

Pass additional plugins to `buildAppComposition(plugins: [...])`. This extends
the built-in execution profile. `buildExecutionRuntime` also accepts this list;
its existing `executionPlugins` argument still replaces the base profile.

```dart
final plugin = PluginDescriptor(
  id: 'my.input',
  factory: FnPluginFactory((context) {
    context.register(MyRouter(), id: 'my.router');
    context.register(MyHandler(), id: 'my.handler');
    return Object();
  }),
);
```

`MyRouter` implements `InputRouter` and can return `InputRoute('my.handler')`.
`MyHandler` implements `InputHandler`. These are ordinary runtime contributions,
not a second plugin registry. Registrations can be revoked; scope disposal owns
plugin cleanup. There is no filesystem plugin loader or configuration-based
router selection added by this change.

Plugins obtain services through declared `ServiceKey` dependencies. A future
classifier plugin should reuse the judgment service and shared spend ledger;
a model-backed handler should use the metered provider factory. Routing itself
performs no model calls and grants no additional tool or permission authority.
Model/agent selection belongs in the selected handler, not in the frontend.
The initial handler contract returns a completed text reply; streaming handlers
are not part of this extension yet.

## Turn ownership

Routing starts when a queued message actually begins its turn. It stays pinned
to that conversation even if the user changes focus. The turn runner owns busy
state, cancellation, queued messages and usage persistence. A routed reply skips
agent compaction and execution. The original user input is written before the
handler starts, followed by its reply; pass-through routing leaves history alone
so the ordinary agent writes the input exactly once. Routing failures and
cancellations are also recorded.

Cancellation interrupts waits on both routers and handlers. Plugins receive the
same cancellation signal and must stop their own requests/work. The host ignores
late results, so a stalled plugin cannot hold the input open or append to a later
turn. Routing plus handler execution has a five-minute deadline by default;
`InputRoutes(scope, timeout: ...)` can change it. Deadline expiry also signals
cancellation. Interactive double-Esc uses the existing cancel-and-clear path;
headless Ctrl+C cancels the same routing/agent turn.

Before routing, the headless frontend may construct its ordinary provider/driver
and run the existing local tree-health check. It sends no agent model request
until routers have passed. Routers see the raw `--prompt`, before the headless
summary instruction and tree-health text are added to the agent's prompt.
