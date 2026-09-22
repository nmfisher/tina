# Agent middleware

Plugins control agent input and model requests through `AgentMiddleware` in
`tina_engine`. The agent loop has no special AGENTS.md or skill loading branch.

```text
User input -> InputProcessor / routing / queue
  -> agent invocation -> beforeInvocation
  -> beforeRequest -> provider decorators -> model
  -> tool dispatch (permissions, checks, cancellation)
  -> beforeRequest -> model ...
```

Delegated and workflow agents enter at the invocation boundary. `beforeRequest`
also runs for transport retries and compaction, with an explicit stage so plugins
can choose where to apply. Existing input routing and provider decorators retain
their responsibilities: queue admission and transport behavior respectively.

## Contract

An `AgentMiddleware` is a `Component` registered using `context.register`.
Implement either or both methods:

- `beforeInvocation(AgentContext, AgentInput)` runs once per turn. It can change
  the text admitted to the agent and that invocation's base system instructions.
  The admitted text becomes the recorded user message, as with input transforms.
- `beforeRequest(AgentContext, AgentRequest)` runs before each model request. It
  can change system instructions, select or transform messages, and narrow the
  advertised tools. These request-only changes do not rewrite saved history.

Both return `AgentDecision.next(value)`, `AgentDecision.reply(text)`, or
`AgentDecision.stop()`. Reply and stop end the current turn without a model call.
The runtime records and presents replies. A plugin can await a user decision via
the existing interruption service, or invoke another component and return its
reply; it must use those components' cancellation and ownership contracts.

`AgentContext` contains the invocation/agent when managed, working directory,
project trust flag, model name, detached history, stage, step, attempt and a
cancellation signal. Bare agents have no managed invocation identity. Context
belongs to one boundary; its cancellation signal closes when the work is done.
Plugins choose what to load and where from, using services captured at plugin
registration. They may use the existing instruction types and observers to
retain provenance, but middleware is not limited to instruction files. Source
categories are open: plugins can use `InstructionKind('example.remote')` without
changing an engine enum.

## Ordering and lifetime

The pipeline reads live contributions at each boundary, parent scopes first,
then registration order within a scope. Explicit middleware supplied directly to
an engine agent runs before scoped contributions. Each plugin sees the previous
plugin's result; a terminal decision skips later plugins.

Plugin removal, addition or replacement during preparation invalidates that
pending request. Cancellation releases even an uncooperative plugin wait; late
results cannot send a request. Exceptions and per-plugin timeouts (30 seconds by
default, overridable) stop preparation with `AbortedKind.preparation`. Plugins
must stop their own I/O on cancellation. Holds prevent new requests and replies
until the user decision settles. They do not undo already-running tools.

The host checks the prepared binding immediately before dispatch and closes the
context afterwards. `Agent` does this; replacement `AgentDriver` implementations
receive the same pipeline and prompt context in `AgentDriverRequest` and must
honor these boundaries in their own loop. Provider ownership remains with the
caller. No second agent queue or invocation registry is introduced.

## Runtime invariants

Requests are detached, deeply immutable snapshots. Their changes are checked
against the actual tool schemas; adding, redefining or duplicating tools is
rejected. Calls to tools hidden by middleware are returned as errors without
execution. Permission, phase and sandbox checks remain in `ToolExecutor`.
The request input budget is checked after middleware finishes, including added
instructions. Middleware cannot replace the cancellation or persistence wiring.

## AGENTS.md and skills

The default execution profile registers `agentsInstructionsPlugin()`. It reads
AGENTS.md upward from the runtime project root before each ordinary model request,
retains root-first precedence, applies size limits, and publishes instruction
observations after the trust check. It skips compaction. The base system prompt
contains identity/environment/static contributions; request-time instructions
are added afresh, so changes do not accumulate or become stale between tool steps.
A custom profile can omit or replace this plugin. Standalone engine callers must
explicitly install middleware; `resolveMainPrompt` no longer reads AGENTS.md.

The skill registry stays lazy. A middleware can list summaries, choose skills
using its own policy, then load bodies only when needed. No scanner or automatic
skill-selection policy is added by this refactor. For example:

```dart
class ReviewContext extends AgentMiddleware {
  final Skills skills;
  ReviewContext(this.skills);
  String get id => 'example.review-context';
  String get name => 'Review context';

  Future<AgentDecision<AgentRequest>> beforeRequest(
      AgentContext context, AgentRequest request) async {
    if (context.stage != AgentStage.request) {
      return AgentDecision.next(request);
    }
    final skill = await skills.load('review',
        cwd: context.cwd, cancelSignal: context.cancelSignal,
        use: SkillUse.model);
    return AgentDecision.next(skill == null ? request : request.copyWith(
        system: '${request.system}\n${skill.content}'));
  }
}
```

Register from a plugin requiring `skillsServiceKey`:

```dart
context.register(ReviewContext(
    context.require(skillsServiceKey).forScope(context.scope)));
```

The example loads a particular skill for normal requests; a real plugin can
choose based on input, tool results, files, or another component's classification.
No automatic instruction analysis or rule conversion is enabled here.
