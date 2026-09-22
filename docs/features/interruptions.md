# Components, invocations, and interruptions

A component is an identifiable capability: an agent, classifier, or input
handler. An invocation is one call to it. The same component can have several
invocations at once. Plugins register components and own their dependencies;
they do not need a second registry.

`Component` contains `id` and `name`. Specialized interfaces retain their typed
operations (`InputProcessor.process`, `ClassificationExecutor.execute`, etc.).
`ComponentInfo` adapts implementations that do not implement `Component`.
`PluginContext.register` can use a component's ID when no explicit ID is supplied.
Standalone classification interfaces do not depend on Tina's runtime or UI.

## Runtime

The execution runtime exposes `invocationsServiceKey` and `interruptsServiceKey`.
An invocation records its component, conversation, input ID, optional parent,
state, completion, and cancellation reason. Completed invocations leave the live
registry. These are in-memory controls, not persisted jobs that resume after exit.

`Invocation.run` passes an `InvocationContext`. Existing typed drivers and tools
also access it through `InvocationContext.current`, an asynchronous zone scoped
to that call. Concurrent calls do not share a mutable global current invocation.
Use a qualified import of `package:tina_engine/invocation.dart` when naming the
type explicitly: Dart also has `dart:core.Invocation`. The main engine barrel
exports the services and context but leaves that conflicting type out.

The input executor creates the target invocation before running processors.
`InputContext.target` identifies it (it is null for standalone input preparation); `InputContext.invocation` identifies the
processor's current invocation. They are peers with the same input ID.
`input.background(future)` keeps the processor invocation alive after forwarding
the input. Plugin removal, conversation closure, and emergency cancellation stop
that background work through its cancellation signal.

Delegated agents called from an invocation become children. They inherit holds
and cancellation; siblings such as the input classifier remain independent.
Tool calls retain their existing tool-use IDs and execute under their owning
agent invocation.

## Requesting an interruption

An input plugin can declare `interruptsServiceKey` as a dependency and receive
the service using `context.require(interruptsServiceKey)`. Its processor can do:

```dart
InputDecision process(InputContext input) {
  final source = input.invocation!;
  final target = input.target;
  if (target == null) return const InputDecision.pass();
  input.background(() async {
    final proposal = await classify(input);
    if (proposal == null || source.isCancelled) return;
    await interrupts.ask(
      source: source,
      target: target,
      title: proposal.title,
      message: proposal.description,
      onAccepted: () => performReplacement(proposal),
    );
  }());
  return const InputDecision.pass();
}
```

`classify` and `performReplacement` are the plugin's typed operations. They must
observe cancellation. Model work uses the existing metered services; tools use
the shared executor and its existing permission checks.

Put the accepted action in `onAccepted`: the conversation queue remains parked
until that callback settles. Do not enqueue replacement work through the same
turn queue and then wait for that queue inside the callback. That queue is held
for the callback; invoke the replacement component directly instead.

This infrastructure does not enable a Git handoff or change the Git classifier's
current status-only behavior.

## Decision and cleanup

1. The service validates that source and target belong to its runtime and the
   same conversation. A source cannot target itself or its ancestor.
2. Requests are serialized per conversation. The active request acquires its
   own hold before presenting the inline choice. Stale requests are cancelled.
3. The target waits before starting model requests, approvals, and tool dispatch,
   including retries. Provider subscriptions pause; other presentation events
   queue in order. Parent holds also collect child output.
4. Decline releases only this request's hold and resumes buffered output. Other
   holds, including the separate session budget pause, remain intact.
5. Accept cancels the target and owned children. The service joins their cleanup
   before calling `onAccepted`. The cancellation reason identifies the source.
6. Source cancellation, plugin removal, or presenter failure releases the hold.
   Headless runtimes return `unavailable` without holding anything.

The terminal's `Prompts` coordinator owns keyboard focus. It suspends an existing
approval or question without answering it, then restores its selection on
decline. Double-Esc cancels affected work and prompts and returns editor control.
Cancellation suppresses late output and new dispatch even while cleanup settles.

The output buffer has a size limit. Provider subscriptions propagate pauses to
their underlying stream. A producer that cannot pause is cancelled if it exceeds
the limit, instead of silently dropping events and resuming an incomplete answer.
Pausing local consumption does not guarantee that remote generation stops.

Unseen model completions and summaries wait before entering the transcript.
Acceptance discards these provisional results. Already dispatched tools can
still finish; their real results remain recorded, including when cancellation
was requested. Cancellation cannot undo external effects. Replacement work waits
for the target to settle, rather than racing an uncooperative active tool.

Replacement agent drivers must honor `InvocationContext` at execution and
transcript boundaries. `AgentDriverRequest.sink` supplies controlled presentation;
the metered provider and `ToolExecutor` enforce their own dispatch boundaries.
