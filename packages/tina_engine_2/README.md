# tina_engine_2

A standalone review artifact: one agent loop, one plugin interface, one
scripted provider. Small enough to read in one sitting. Built on
`tina_core` — its value types (messages, tools, tool calls, results) and
its streaming `LlmProvider` are the ones used here.

The root executable uses this loop through `tina_host` and `tina_tui`.

Dart standard library only, plus `tina_core` (path dependency). No network.
No persistence. The point is to judge the design, not the coverage.

## Layout

```
lib/tina_engine_2.dart     barrel export
lib/src/loop.dart          the loop. One file. Five steps, top to bottom.
lib/src/model.dart         the value types (immutable)
lib/src/plugin.dart        AgentPlugin: one interface, every hook optional
lib/src/context.dart       the per-turn context plugins receive + the cancel token
lib/src/provider.dart      the provider interface + the scripted provider
example/example_plugins.dart  four small plugins, hooks in use
test/engine_2_test.dart    the required scenarios, streaming edges, the copy rule
```

## The two rules

**The core owns truth. The plugins own decisions.**

- The core owns the transcript. It is the only writer. A plugin never edits
  history; it writes to the context copy it is handed and the loop acts on
  what arrives.
- A plugin decides, the core acts. Deny a tool, rewrite a request, add a
  prompt section — the plugin says what, the core does it and records it.

Everything else in this file follows from those two lines.

## The loop, in five steps

```
1. take one input (from the caller, or a queue the caller supplies)
2. build the request (joined prompt sections + history + pinned tools)
3. call the provider
4. run the tool calls it asked for
5. append results, go to 3 until the model asks for no tools
```

That is all `loop.dart` does — one file, read top to bottom: take the
input, build the request, call the model, run the tool calls, append the
results and repeat. Budgets, retries, compaction, pruning, checkpoints are
deliberately not in it. See "Left out on purpose".

## The model

Value types come from `tina_core` and are immutable. `Request` snapshots
are copies, never live views; the one mutable thing is `TurnContext`, and
the loop copies it per plugin call (see the copy rule below).

| Type | What it is |
| --- | --- |
| `Message` | one transcript entry: `Role` + content blocks (`TextBlock`, `ToolUseBlock`, `ToolResultBlock`). |
| `ToolSchema` | name + description + JSON schema map. No executor inside. |
| `ToolUse` | a `tool_use` from the model: id, name, input. |
| `ToolResult` | the matching `tool_result` the core writes. |
| `Input` | one user input: text + an id. Enters the loop once. |
| `Request` | one model request: system prompt, messages, tools. Immutable. |
| `Outcome` | what a turn produced: messages appended, stop reason, usage. |
| `TurnContext` | what a plugin sees and writes: input, messages, prompt sections, pinned tools, the call, the result, the decision, the outcome. |

`Input`, `Request`, `Outcome`, `StopReason`, `Decision` and `DecisionKind`
are loop-only types, defined in `lib/src/model.dart`. They are not shared
value types and do not belong in `tina_core`.

## The plugin interface

One abstract class. Every hook has a default that does nothing, so a plugin
implements only what it needs.

```dart
abstract class AgentPlugin {
  String get id;                              // required, unique
  int get order => 100;                       // ordering, one integer
  List<ToolSchema> get tools => const [];     // tools contributed
  void onPrompt(TurnContext c) {}             // add a prompt section
  void onInput(TurnContext c) {}              // rewrite the input
  void beforeModelCall(TurnContext c) {}      // shape the per-call request
  void beforeToolCall(TurnContext c) {}       // the guard: set c.decision
  void afterToolResult(TurnContext c) {}      // observe/replace the result
  void onTurnEnd(TurnContext c) {}            // the turn ended
}
```

Every phase is a `TurnContext` in, nothing out: the plugin reads what it
needs and assigns what it wants to change. The loop copies the context
before each call and keeps the copy the plugin wrote.

### The copy rule

Before every plugin call the loop copies the context — `copy()` makes new
lists with the same elements — and hands the copy over. The plugin writes
to its copy; the loop keeps the copy it wrote and hands the *next* plugin
a copy of that, so later plugins see earlier writes. A plugin that throws
has its copy dropped. Enforcement hooks fail closed; end-of-turn notification
failures are recorded while remaining cleanup hooks continue. The cancellation
token is shared and payload copies are shallow, so external side effects cannot
be rolled back.

### Hooks, one paragraph each

**`id` / `order`** — identity and ordering. `id` must be unique; registering
a duplicate id throws. `order` sorts plugins everywhere: prompt sections,
request transforms, guards. One integer, no priorities-of-priorities.

**`tools`** — the tools this plugin gives the loop. The core takes one
snapshot of the full tool set at the turn boundary and pins it for the whole
turn. A plugin that changes its `tools` list mid-turn is rejected (see
invariants below).

**`onPrompt`** — runs once per turn, before the input phase, in ascending
`order`. The plugin adds one section to `c.promptSections` — or adds
nothing. The core owns the join: it puts the newlines between sections and
drops empty ones, so no plugin can hand over a whole prompt. With no
sections the prompt is an empty string: the core owns no prompt text, so
the persona lives in a plugin (in tina_host), not here.

**`onInput`** — first hook of a turn, right after the prompt phase. The
input is `c.input`; a rewrite is an assignment. Runs in `order`. The
caller's original is untouched — the loop copies the context — and the
outcome records which plugin, if any, changed it.

**`beforeModelCall`** — runs before every model call, not once per turn, so
a plugin can shape each request as the conversation grows. `c.messages`,
`c.promptSections` and `c.pinnedTools` are the request about to be built;
edit them by assignment. Runs in `order`. This is where a pruning or
redaction plugin would live — the loop itself never rewrites what the
model is about to see, and the transcript is untouched: a plugin edits
its copy of the message list, never the truth.

**`beforeToolCall`** — the guard. Called before each tool executes, in
`order`. The call is `c.call`; set `c.decision` to `Decision.deny` or
`Decision.ask` — or leave the allow that is already there. All guards
must pass; `order` only decides which one reports first, and the first
non-allow decision stops the guard phase. In this package `ask` has no UI
to route to, so it resolves to deny — recorded as `ask-unresolved` in the
result content, an explicit and visible fallback, not a silent one.

**`afterToolResult`** — called after a tool result exists, in `order`. The
result is `c.toolResult`; assign to it to replace what the core records,
or leave it to observe only. The loop enforces pairing either way:
whatever is recorded, the core writes it, and a `tool_use` always ends
with a `tool_result`.

**`onTurnEnd`** — the turn is over. The outcome is `c.outcome` (final
answer, stop reason, message count). A place for metrics or logging, not
for mutation.

## The invariants

1. **One writer.** The loop owns the transcript. Plugins get a copy of the
   context, write to it, and the loop keeps what they wrote — but history
   is never rewritten from a plugin: the loop refreshes the context from
   its own truth each step. A plugin edits its copy of the message list,
   never the transcript.
2. **Pairing.** Every `tool_use` gets a matching `tool_result`. The loop
   enforces it, always. A denied tool still produces a result that says so.
   No orphans, ever.
3. **Cancellation.** One cancellation path: the `CancelToken` the context
   holds (`cancel()`, `cancelled`, `cancelReason`). Set it once. The loop
   checks it at the same points every time — before the model call, before
   each tool — stops promptly, and records why. There is no second
   mechanism.
4. **Pinned tools.** The tool set is read once at the turn boundary and does
   not change during the turn. If the plugin list reports a different tool
   set mid-turn, the loop rejects the turn with `error:tools-changed`.
5. **Liveness.** A plugin can be removed mid-turn. Before dispatching a
   tool, the loop re-checks that the owning plugin is still registered. If
   it is gone, the call is skipped: a `tool_result` is written saying the
   plugin left, and the turn continues. No crash. The check is at dispatch:
   a removal inside the guard loop for the same call does not undo it (see
   open question 8).
6. **Fail closed.** Input/prompt/request failures prevent provider calls. Tool
   guard failures block dispatch; result-hook failures preserve pairing without
   replaying side effects. End-hook failures do not change a committed outcome.
7. **Unique ids.** A duplicate plugin `id` is a programming error. It throws
   at registration.

## Ordering rules

- Prompt sections: ascending by `order`. Stable sections first, volatile
  ones last. The join belongs to the core.
- Per-call request shaping: in `order`.
- Tool guards: all must pass. `order` only decides which one reports first.
- Hooks may be asynchronous and are awaited in order. Cancellation interrupts
  pending enforcement hooks; late writes and errors cannot authorize work.

`order` is a single integer compared ascending. Ties are broken by plugin id
so the sequence is the same every run — byte order is reproducible.

## The provider

`tina_core`'s streaming interface, re-exported by the barrel:

```dart
abstract class LlmProvider {
  final String model;
  LlmProvider(this.model);
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  });
  void close() {}
}
```

The loop consumes that stream: `ToolCallStart` announces each tool call the
model asks for, text deltas accumulate the answer, and `MessageComplete`
carries the final content blocks the transcript records. A `StreamError`
ends the turn as `error` with the failure recorded.

The **scripted provider** ships in the same package for tests. It plays
back scripted event streams — one per request — and records every request
it received. No network, no API. Tests assert on the recorded requests,
which is how the invariants get pinned: pairing, pinning, ordering,
isolation.

## Left out on purpose

Each omission is a decision, not a gap. The brief asked for a loop that can
be judged; each of these either belongs behind a hook that already exists,
or is out of scope for a review artifact.

- **Persistence** — absent. Saving transcripts is storage policy, not loop
  semantics. The loop emits the transcript on every turn end (`Outcome`
  carries the messages); a future package can write it anywhere. Nothing in
  the loop needs to know.
- **Sub-agents** — absent. A sub-agent is another loop with its own
  transcript and its own lifecycle. Wiring it in would mean the loop knows
  about spawning, which is exactly the coupling this package exists to
  question. If wanted, it is a tool whose implementation owns a nested loop.
- **Retries** — absent. A retry is a policy about the provider boundary.
  It would wrap `Provider.call` in a decorator. It is not loop semantics,
  and putting it in the loop would make every provider see loop-owned
  retry state.
- **Token budgets** — absent. A budget decides when to stop or compact, and
  there is no real tokenizer here (no network, no model). It is also a
  cross-turn policy, while the loop is per-turn. Behind a plugin, it would
  live in `beforeModelCall`.
- **Compaction** — absent. Compaction rewrites history, and the core owns
  history. Getting it right needs a real summarizer and a real policy about
  what may be dropped. `beforeModelCall` is the seam where it would attach,
  once there is something real to compact.
- **Tool-result pruning** — the same story as compaction, smaller. It is
  the canonical `beforeModelCall` example plugin: edit the request's
  message list on the context, leave the transcript alone.
- **Providers** — the interface is here; real HTTP providers are not. No
  network in this package by design. Shipping one would make this package
  depend on http and on key management, which are someone else's problem.
- **UI** — absent, including for `Decision.ask`. There is no approval UI,
  so `ask` resolves to deny and the fallback is recorded. A real host would
  supply an ask-handler; this package does not pretend to have one.

## Open questions

1. **Should a guard be able to rewrite the call?** Right now a guard can
   allow or deny, but not edit `c.call`. A modify path would cover
   redaction but adds a second way to change what the model asked for.
   Left out to keep the decision enum honest.
2. **Is `ask` resolving to deny right?** With no UI it is the only safe
   fallback, but a host may prefer fail-closed-to-allow with an audit note.
   The recording makes either auditable; the default is a judgement call.
3. **Where does the header for the prompt join live?** The core inserts one
   blank line between sections. Whether that belongs in the core or in a
   prompt-assembly plugin is not settled; core keeps the join deterministic
   and out of plugin hands, which matches "a plugin returns a section,
   never a whole prompt".
4. **`afterToolResult` replacement scope.** Today a plugin can replace a
   result the core records, but not what the model already saw in the
   *current* request. Replacing after the fact is useful for audit but may
   mislead the model in the same turn. Needs a real use to decide.
5. **Turn-boundary tool pinning vs. plugin liveness.** Pinning the schema
   set at the boundary while allowing plugins to leave mid-turn means a
   pinned tool can become undispatchable. The loop writes an explanatory
   result. An alternative is to re-pin at each request; that breaks the
   pinning invariant. Both costs are real; the brief's invariants were kept
   as written.
6. **No async plugins.** Phases are sync on purpose: the loop stays
   sequential and easy to reason about. If a hook ever needs I/O, either
   the hook goes async or the plugin precomputes. Not decided here.
7. **Error taxonomy.** Stop reasons are a small enum plus a free-form
   `detail` string. A richer typed error channel might be needed once a
   second consumer exists. One consumer now; not built.
8. **Guard-loop removals.** The liveness check runs once, at dispatch. A
   guard that removes the owning plugin during the same call's guard loop
   does not stop the executor that dispatch just approved. Re-checking
   after every guard would close that window but re-reads the registry
   per guard; not settled.

## What "done" means here

```
dart pub get && dart analyze && dart test
```

in `packages/tina_engine_2`, all clean.

## Optional limits and stop metadata

The loop has no step ceiling. `tina/step-limit` is an opt-in plugin; zero means
unlimited. It counts foreground rounds, not individual tool calls. The plugin
snapshots its global configuration at each input; child sessions do not implicitly
inherit it.

Plugins use `TurnContext.requestStop` to stop with an attributed code/detail.
The engine supplies the actual invoking plugin ID. A policy stop uses the existing
`cancelled` terminal reason plus optional `stop` metadata, readable by older
readers (which ignore the extra metadata). `onTurnEnd` is awaited even after
cancellation, and hook failures are available through `AgentLoop.hookFailures`.
