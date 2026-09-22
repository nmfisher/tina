# Instruction rule framework

This is infrastructure only. Tina does not analyze instructions, propose rules,
activate rules, or make new classification requests. Existing prompts and tool
permissions retain their behavior when no plugin uses these interfaces.

## Loaded instructions

`Instruction` in `tina_engine` carries source identity, kind, source URI (when
known), applicability scope, admitted text, completeness, and a SHA-256 revision
of the full source text. `InstructionRef` binds a rule to an exact revision without
copying the body. IDs are interpreted within the loading project/plugin context.
A skill's source URI is its provider's resource base, not an invented file path.

A plugin registers an `InstructionObserver` with `PluginContext.register`.
The default AGENTS.md middleware publishes a root-first snapshot before normal
model requests, only after the project trust check. An empty snapshot allows a consumer to notice removed instructions.
`Skills.load` publishes only a successfully loaded, accessible body. `Skills.list`
still reads metadata only. Parent observers receive child loads; disposed
registrations receive nothing. Observer failures do not break loading.

Callbacks must be short. A future analyzer schedules work in its own cancellable
`Invocation`, with lifetime owned by its plugin. Repeated request preparation may repeat
notifications; deduplicate by source, scope and revision. Loads with unreadable, omitted or truncated instructions are marked incomplete
and are not complete evidence. These events describe admitted instructions, not an
independent filesystem scan or permission to read linked resources.

## Rules and proposals

The application layer defines:

- `Rule<C, I, O>`: a registered component. It creates an existing
  `ClassificationTask<I, O>` from boundary context `C`, then maps its classification
  to a separate `RuleDecision` (`proceed`, `block`, `review`).
- `RuleConfig`: a portable reference to the implementation ID/revision, source
  instruction revision, trigger (`input`, `tool`, `result`), and JSON settings.
- `RuleAnalyzer`: an optional plugin contract producing `RuleProposal` candidates.
- `RuleRecord`: a proposal and its proposed/enabled/dismissed/stale review state.
- `RuleStore`: a project-scoped persistence contract, with versioned JSON records.

No analyzer, rule runner, registry resolver, storage backend, or built-in rule is
installed. Registering a rule component alone never enables it. Future adapters
must resolve the exact registered implementation and source revision before using
an enabled record. Missing or changed sources/implementations require review.
Dismissals are revision-specific too. Keep original prose in prompts.

Classification uses the existing sources, encoders, plans, orchestrator, budgets,
and cache. A rule task must include the relevant boundary evidence in its source
revision. A check for one tool call must not reuse a result for another call solely
because the instruction was unchanged. Policy must explicitly handle unknown,
partial evidence, classifier errors and source changes. Mandatory checks do not
make statistical classification infallible.

## Execution and review

Input routing already has `InputProcessor`; result processing has
`ToolResultHook`. New `ToolCheck` contributions provide an awaited boundary before
actual tool dispatch, including outside-sandbox retries. They see the sealed tool
arguments, prepared process request when available, and sandbox mode. They return
null to continue or a blocking explanation. Checks cannot execute or replace the
tool, and a pass cannot override permission or phase guards.

The executor runs checks in registration order, with a per-check timeout and a
cancellation signal. Timeout, exception or removal of a mounted check blocks the
pending call. Cancellation releases the wait even if a plugin ignores its signal;
late results cannot dispatch a tool. Implementations must cancel their own I/O and
must not perform tool side effects. Final permission, phase, hold and cancellation
checks still run after asynchronous checks. Main, delegated and workflow agents
receive these contributions through the existing composition paths. As with
other execution contributions, mounting happens when the runtime is composed.

`Interrupts.ask(mode: InterruptMode.review)` uses the existing conversation queue
and presenter. It holds the target's output/dispatch, runs the accepted callback
while the target is held, then resumes it. Declining also resumes it. The default
`handoff` mode still cancels and joins the target on acceptance. Review does not
undo a tool already executing, and its callback must not await work by the held
target. Callbacks must honor their source invocation's cancellation. No new UI
or rule approval workflow is installed.

The future feature can therefore connect:

```text
AGENTS.md / Skills.load
  -> InstructionObserver -> analyzer Invocation -> RuleProposal
  -> Interrupts review -> RuleStore

InputProcessor / ToolCheck / ToolResultHook
  -> resolve enabled RuleConfig -> Rule.task
  -> ClassificationOrchestrator -> Rule.decide -> boundary action
```
