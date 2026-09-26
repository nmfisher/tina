# tina_engine_2

A standalone review artifact: one agent loop, one plugin interface, one
scripted provider. Small enough to read in one sitting.

It is **not** wired into tina. Nothing depends on it. Nothing here replaces
`packages/tina_engine`.

Dart standard library only (`dart:async`, `dart:collection`). No network.
No persistence. The point is to judge the design, not the coverage.

## Layout

```
lib/tina_engine_2.dart     barrel export
lib/src/model.dart         the value types (immutable)
lib/src/plugin.dart        AgentPlugin: one interface, every hook optional
lib/src/loop.dart          the loop. One file. Five steps.
lib/src/provider.dart      the provider interface + the scripted provider
lib/src/context.dart       the per-turn snapshot plugins receive
example/example_plugins.dart  four small plugins, hooks in use
test/engine_2_test.dart    the eight required scenarios
```

## The two rules

**The core owns truth. The plugins own decisions.**

- The core owns the transcript. It is the only writer. A plugin never edits
  history; it sees snapshots and returns decisions.
- A plugin decides, the core acts. Deny a tool, rewrite a request, add a
  prompt section — the plugin says what, the core does it and records it.

Everything else in this file follows from those two lines.

## The loop, in five steps

```
1. take one input (from the caller, or a queue the caller supplies)
2. build the request (system prompt + history snapshot + pinned tools)
3. call the provider
4. run the tool calls it asked for
5. append results, go to 3 until the model asks for no tools
```

That is all `loop.dart` does. Budgets, retries, compaction, pruning,
checkpoints are deliberately not in it. See "Left out on purpose".

## The model

All types are immutable. Snapshots are copies, never live views.

| Type | What it is |
| --- | --- |
| `Input` | one user input: text + an id. Enters the loop once. |
| `Message` | one transcript entry: `user`, `assistant`, `tool_result`. |
| `Tool` | name + description + JSON schema map. No executor inside. |
| `ToolCall` | a `tool_use` from the model: id, name, arguments. |
| `ToolResult` | the matching `tool_result` the core writes. |
| `Request` | one model request: system prompt, messages, tools. Immutable. |
| `Outcome` | what a turn produced: messages appended, stop reason, usage. |
| `Context` | what a plugin sees: transcript snapshot + read-only registries. |

## The plugin interface

One abstract class. Every hook has a default that does nothing, so a plugin
implements only what it needs.

```dart
abstract class AgentPlugin {
  String get id;                                  // required, unique
  int get order => 100;                           // ordering, one integer
  List<Tool> get tools => const [];               // tools contributed
  String? systemSection(Context c) => null;       // a prompt section
  Input? beforeInvocation(Context c, Input i) => null;  // rewrite input
  Request? beforeRequest(Context c, Request r) => null; // rewrite request
  Decision beforeTool(Context c, ToolCall call) => Decision.allow;
  Object? afterTool(Context c, ToolResult r) => null;   // observe/transform
  void onTurnEnd(Context c, Outcome o) {}         // the turn ended
}
```

### Hooks, one paragraph each

**`id` / `order`** — identity and ordering. `id` must be unique; registering
a duplicate id throws. `order` sorts plugins everywhere: prompt sections,
request transforms, guards. One integer, no priorities-of-priorities.

**`tools`** — the tools this plugin gives the loop. The core takes one
snapshot of the full tool set at the turn boundary and pins it for the whole
turn. A plugin that changes its `tools` list mid-turn is rejected (see
invariants below).

**`systemSection`** — a **method**, not a property, so it can return live
text. The core calls it once per turn when the prompt is assembled, in
ascending `order`. It returns one section. The core owns the join: it puts
the newlines between sections, so no plugin can hand back a whole prompt.
Stable sections first, volatile ones last — by convention the core's own
header is first, so anything with a high `order` lands at the end.

**`beforeInvocation`** — first hook of a turn. Gets the user `Input` and a
context snapshot. Returns a new `Input` (rewritten text, new id) or null to
leave it alone. Runs in `order`. Because it returns a new immutable value,
the caller's original is untouched; the core records which plugin, if any,
changed it.

**`beforeRequest`** — runs before every model call, not once per turn, so a
plugin can transform each request as the conversation grows. Gets a full
`Request` snapshot; returns a new `Request` or null. Runs in `order`. This
is where a pruning or redaction plugin would live — outside the loop, which
is why the loop file stays short.

**`beforeTool`** — the guard. Called before each tool executes, in `order`.
Returns `Decision.allow`, `Decision.deny`, or `Decision.ask`. All guards
must pass; `order` only decides which one reports first. In this package
`ask` has no UI to route to, so it resolves to deny — recorded as
`denied:ask-unresolved`, an explicit and visible fallback, not a silent one.

**`afterTool`** — called after a tool result exists, in `order`. May return
a replacement result that the core records instead, or null to observe only.
The loop enforces pairing either way: whatever is recorded, the core writes
it, and a `tool_use` always ends with a `tool_result`.

**`onTurnEnd`** — the turn is over. The core hands the plugin the `Outcome`
(final answer, stop reason, message count) and a snapshot. Return value is
ignored. A place for metrics or logging, not for mutation.

## The invariants

1. **One writer.** The loop owns the transcript. Plugins get snapshots and
   return decisions. A plugin can never mutate history — and a plugin that
   tries is rejected.
2. **Pairing.** Every `tool_use` gets a matching `tool_result`. The loop
   enforces it, always. A denied tool still produces a result that says so.
   No orphans, ever.
3. **Cancellation.** One cancellation path: the `cancelled` field on
   `Context`. Set it once. The loop checks it at the same points every time
   — before the model call, before each tool — stops promptly, and records
   why. There is no second mechanism.
4. **Pinned tools.** The tool set is read once at the turn boundary and does
   not change during the turn. If the plugin list reports a different tool
   set mid-turn, the loop rejects the turn with `error:tools-changed`.
5. **Liveness.** A plugin can be removed mid-turn. Before dispatching a
   tool, the loop re-checks that the owning plugin is still registered. If
   it is gone, the call is skipped: a `tool_result` is written saying the
   plugin left, and the turn continues. No crash. The check is at dispatch:
   a removal inside the guard loop for the same call does not undo it (see
   open question 8).
6. **Isolation.** A plugin that throws in a hook must not break the turn.
   Its contribution is treated as absent and the turn continues. (Brief
   ordering rules; enforced for every hook, including lifecycle hooks.)
7. **Unique ids.** A duplicate plugin `id` is a programming error. It throws
   at registration.

## Ordering rules

- Prompt sections: ascending by `order`. Stable sections first, volatile
  ones last. The join belongs to the core.
- Request transforms: in `order`.
- Tool guards: all must pass. `order` only decides which one reports first.
- A throwing plugin is isolated: its contribution is absent, the turn goes
  on. One bad plugin must never break every prompt or every turn.

`order` is a single integer compared ascending. Ties are broken by plugin id
so the sequence is the same every run — byte order is reproducible.

## The provider

```dart
abstract class Provider {
  Future<ProviderResponse> call(Request request);
}
```

Tiny. One method. The loop takes whatever implements it.

The **scripted provider** ships in the same package for tests. It plays
back a queue of scripted responses and records the requests it saw. No
network, no API. Tests assert on the recorded requests, which is how the
invariants get pinned: pairing, pinning, ordering, isolation.

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
  live in `beforeRequest`.
- **Compaction** — absent. Compaction rewrites history, and the core owns
  history. Getting it right needs a real summarizer and a real policy about
  what may be dropped. `beforeRequest` is the seam where it would attach,
  once there is something real to compact.
- **Tool-result pruning** — the same story as compaction, smaller. It is
  the canonical `beforeRequest` example plugin: rewrite the request
  snapshot, leave the transcript alone. Shown as an example, not built in.
  (The example prunes only its own tool's results, by name, and never
  rewrites history.)
- **Providers** — the interface is here; real HTTP providers are not. No
  network in this package by design. Shipping one would make this package
  depend on http and on key management, which are someone else's problem.
- **UI** — absent, including for `Decision.ask`. There is no approval UI,
  so `ask` resolves to deny and the fallback is recorded. A real host would
  supply an ask-handler; this package does not pretend to have one.

## Open questions

1. **Should `beforeTool` be able to return a replacement call?** Right now a
   guard can allow or deny, but not rewrite arguments. A `modify` decision
   would cover redaction but adds a second path that changes what the model
   asked for. Left out to keep the decision enum honest.
2. **Is `ask` resolving to deny right?** With no UI it is the only safe
   fallback, but a host may prefer fail-closed-to-allow with an audit note.
   The recording makes either auditable; the default is a judgement call.
3. **Where does the header for the prompt join live?** The core inserts one
   blank line between sections. Whether that belongs in the core or in a
   prompt-assembly plugin is not settled; core keeps the join deterministic
   and out of plugin hands, which matches "a plugin returns a section,
   never a whole prompt".
4. **`afterTool` replacement scope.** Today a plugin can replace a result
   the core records, but not what the model already saw in the *current*
   request. Replacing after the fact is useful for audit but may mislead
   the model in the same turn. Needs a real use to decide.
5. **Turn-boundary tool pinning vs. plugin liveness.** Pinning the schema
   set at the boundary while allowing plugins to leave mid-turn means a
   pinned tool can become undispatchable. The loop writes an explanatory
   result. An alternative is to re-pin at each request; that breaks the
   pinning invariant. Both costs are real; the brief's invariants were kept
   as written.
6. **No async plugins.** Hooks are sync on purpose: the loop stays
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
