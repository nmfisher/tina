# Input processors and status plugins

Plugins can inspect, transform, route or consume submitted user prompts before
those prompts enter the agent queue. They use the existing plugin registry.

```text
user submission
  → command plugins (slash commands)
  → input processors (sync or async, in registration order)
  → conversation queue (submission order)
  → selected input handler or current agent

input processor → status source → Renderer → strip beneath the input
```

TUI input and headless `--prompt` use the same `InputRoutes` service. Recognized
slash commands keep their [command path](command_plugins.md). A command that
returns `CmdRun` sends its expanded prompt through processors. Unknown commands
follow the ordinary prompt path. Internal workflow results bypass processors;
delegated agent turns and individual tool/model calls are not user submissions.

## Contracts

The input types are exported by `package:tina_app/tina_app.dart`:

- `InputContext`: submission `id`, `conversationId`, `originalText`, current
  `text`, JSON `data`, detached history, `cancelSignal` and `isCancelled`.
- `InputProcessor.process(context)`: returns `FutureOr<InputDecision>`.
- `InputDecision.pass(data: ...)`: continue, optionally adding metadata.
- `InputDecision.replace(text, data: ...)`: replace text for later processors
  and the agent. Empty replacement is an error; use `stop` to consume input.
- `InputDecision.route(InputRoute('handler.id', data: ...))`: select a named
  `InputHandler`, ending processor selection.
- `InputDecision.stop()`: consume the submission without an agent turn.
- `InputHandler.handle(context, route)`: asynchronously returns a text reply.

Metadata is copied and deeply frozen between processors. Later values replace
same-named keys. Metadata is available to later processors and handlers; it is
not automatically inserted into the agent prompt or persisted. A processor can
explicitly replace text if the agent needs additional information.

The context exposes no live driver, host or mutable queue. Plugins return
decisions; the host alone forwards input. Legacy `InputRouter` contributions
remain supported as pass/route processors. Contributions run in registration
order; declare plugin dependencies when that order matters.

## Registering a processor

Pass plugins to `buildAppComposition(plugins: [...])`. `buildExecutionRuntime`
also accepts this list.

```dart
class Rewrite implements InputProcessor {
  @override
  InputDecision process(InputContext input) => InputDecision.replace(
    'Review this request: ${input.text}',
    data: {'rewritten': true},
  );
}

final plugin = PluginDescriptor(
  id: 'my.input',
  factory: FnPluginFactory((context) {
    context.register(Rewrite(), id: 'my.rewrite');
    return Object();
  }),
);
```

A classifier can instead await a typed result, then return `pass`, `replace`,
`route` or `stop`. The frontend does not need to know which classifier or source
was used. Services come from declared `ServiceKey` dependencies. Model requests
must use the normal metered services; processing grants no extra tool authority.

## Ordering, cancellation and history

Independent submissions can prepare concurrently, so a slow classifier does not
hold the editor. Decisions enter the queue in submission order. Selected handlers
run in turn order with ordinary agent turns, avoiding concurrent history writes.
History in each context is a snapshot taken at submission, not a future view of
an earlier turn's eventual reply. Focus changes never change a submission's owner.

The UI echoes the original text. For an agent turn, the ordinary driver records
the effective (possibly transformed) text exactly once. Routed replies record the
original submission followed by the handler reply. Processing failures are
reported in turn order and never silently fall through to the model. `stop`
creates no conversation entry. Original text and metadata remain available in
the context but are not added as a second persisted transcript.

Cancellation interrupts processor and handler waits, including uncooperative
plugins. Double-Esc discards pending admissions, clears queued inputs and cancels
background work. Late decisions cannot enqueue input or append replies. Plugin
removal fails work that still depends on its contribution. Processing and handler
execution each have a five-minute timeout by default (`InputRoutes(timeout: ...)`).
Closing a conversation cancels pending preparation before disposing its resources.

For work that should continue after returning `pass`, call
`input.background(future)`. This registers it for emergency cancellation without
delaying forwarding. The plugin must observe `cancelSignal`, cancel its transport,
and report failures through its own status. Background failures cannot retract an
already forwarded message. Plugin disposal must also cancel owned work.

Headless processing sees the raw prompt; tree-health context and the headless
summary instruction are added to the effective prompt afterwards.

## Git status plugin

Interactive CLI sessions install `configuredGitInputPlugin`. It uses the existing Typesafe/JEV
judgment service and shared spend ledger, independently of the chat model.
`InputTextSource` supplies the latest submitted prompt and up to six recent text
messages. Tool payloads are excluded. `gitClassifier` asks independent questions
for common Git subcommands, `other`, no Git request, and unclear intent. Multiple
subcommands can be selected. Oversized input is unknown rather than being split
across a negation or silently truncated; the full request is checked against the
judgment token budget before dispatch.

By default, `GitInput` immediately passes the prompt and updates status in the
background. `GitInput(check, background: false)` waits and adds the typed result's
JSON to `input.data['git']` before forwarding. A missing service, timeout or request
failure produces an unavailable status and does not block the agent.

Status is keyed by conversation and submission. Newer prompts replace older
status; late results cannot overwrite them. Recognized slash commands that do not
produce an agent prompt do not run this classifier. Results stay in memory and
are not stored in the project index. The indicator predicts intent; it neither
executes Git nor confirms that the agent ran Git.

`StatusSource` exposes `read(conversationId)` and a change stream. The frontend's
`InputStatus` bridge reads the focused conversation and uses registered
`Renderer<T>` contributions to paint the existing strip beneath the editor.
`GitStatusRenderer` supplies the Git labels. Other plugins can publish and render
their own types through the same path. Status updates preserve the editor cursor,
mode label and error notices; plugin removal clears its status.

While classification runs, the status cycles through `| / - \` every 120 ms.
Status renderers request animation with `RenderLine(animated: true)` and read
`RenderContext.animationFrame`. The bridge uses the screen's shared animation
clock and stops when the visible status settles, is removed, or is disposed.

## Interruptions

Processors have their own invocation and can identify the agent invocation for
the same submission through `InputContext.target`. The runtime can hold that
invocation while an inline choice is shown, then resume it or cancel and hand
off. See [Components, invocations, and interruptions](interruptions.md).
