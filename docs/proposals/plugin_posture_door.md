# Proposal: The plugin posture door

Status: PROPOSED — owner to greenlight.
Anchors verified against `main` @ `2118b35` (v0.8.31, 2026-09-25).
Provenance: every file:line below was read in the working tree this session;
the three problem claims are demonstrated from the code in §2, with the
failing-first tests that pin PR #61's rule (all passing on `main`,
`plan_approval_gate_test.dart`) as execution proof.

Companion reading: [Plan approval](../features/plan_approval.md) (the
mechanism this door serves), the decided boundary in
[plugin_architecture.md §11](plugin_architecture.md).

## Problem

PR #61 (`0a5ace6`, "fix(plans): auto-grant update_plan approval when
unattended or yolo", merged as part of v0.8.30) fixed a real stall the
smallest way possible: the plan plugin gained `PlanTool.resolveApprovalMode`,
which reads `policy.allowAllByDefault` and `host.canAnswerQuestions` and
collapses them into a plugin-local `PlanApprovalMode`. The stall is gone,
but the fix put a permission-posture *decision* inside a plugin. Three
concrete problems:

1. **Duplicated posture knowledge.** The fact "`--yolo` means skip prompts"
   now lives in the policy (`policy.dart:250`, `policy.dart:314`) *and* is
   re-derived by `resolveApprovalMode` (`plan_plugin.dart:146-147`). When
   the posture grows a nuance — a permission *mode* other than yolo that
   also implies "no asks", say — the plan gate will not follow: nothing
   points the plugin at the change. The policy can evolve; the plugin's
   copy of its meaning will not.

2. **The answerability seam is plugin-facing, not core-facing.**
   `canAnswerQuestions` is a public field on `HostInterface`
   (`host_interface.dart:49`) that any plugin can read, and its semantics
   ("can someone answer a *question*") are consumed by exactly one plugin
   tool (`plan_plugin.dart:147`). The four hosts that express "nobody can
   answer" for *tool* asks do so in three different, unrelated shapes:
   `HeadlessHost.askPermission` denies with `decidedBy: 'headless'`
   (`headless_host.dart:87-88`), the sub-agent scheduler's `_autoDenyAsker`
   returns `denyOnce` (`sub_agent_scheduler.dart:1352-1353`), and a
   background TUI conversation denies with `decidedBy: 'background'`
   (`tui_conversation_host.dart:244-262`). Answerability is thus a fact
   every mechanism re-derives in its own dialect. A future plugin that
   needs the same fact (a notification plugin deciding whether to page the
   user, say) will invent a fifth dialect.

3. **Stored state loses provenance.** Under `autoGrant`, `PlanTool.execute`
   writes plain `PlanApproval.approved` into the store
   (`plan_plugin.dart:218-224`) — the identical value a human's
   `/plan approve` writes (`plan_plugin.dart:355`). The model-facing text
   is honest ("approved automatically", `plan_plugin.dart:280-282`), but
   the persisted state — including the session-manifest blob the store's
   `persistHook` feeds — is not: a resumed session shows `approved` with
   nothing to distinguish machine grant from human sign-off. The tool side
   solved this exact problem once already: `PermissionResponse.decidedBy`
   and `GrantSource.classifier` exist precisely so a non-human grant never
   masquerades as a user's (`prompt.dart:274-286`, `policy.dart:175-200`).

### The boundary rule this brushes

plugin_architecture.md §11 records the decided boundary: core owns the
permission decision; a plugin must not re-derive policy; the intended shape
is "one narrow read-only door from a plugin into the decision" — the plugin
asks, core decides. PR #61 is the case study in why the door matters: a
sensible, tested fix that nonetheless deepens the plugin-side re-derivation.
The door it should have asked through still does not exist.

## Proposal

Give plugins the door, then move the plugin behind it.

**1. Core owns a `PlanPosture` answer, minted where the policy already is.**
A small immutable value:

```dart
/// Whether (and how) a plugin may pose a human-approval ask in this
/// conversation. Minted by core from the conversation's policy and host;
/// handed to plugins as a read-only fact.
enum AskCapability { answerable, autoGrant, none }

class PlanPosture {
  /// yolo posture, as the POLICY understands it — not re-derived.
  final bool promptsSkipped;
  /// Whether a human can answer an ask in this conversation.
  final AskCapability ask;
}
```

Core computes it once per conversation at composition time — exactly where
`agent_composition.dart:198-220` already wires `policy` and `host` into the
plan pieces — from `policy.allowAllByDefault` (or, better, a new
`policy.mayPoseAsks` that can later absorb mode nuance) and
`host.canAnswerQuestions`. Everything downstream keeps working unchanged:
the plugin's `resolveApprovalMode` shrinks from "derive the rule" to
"consume the handed answer".

**2. Fold the three answerability dialects into the minted value.**
`HeadlessHost`/`InvocationHost`/`TuiConversationHost` already know what they
want to say; `PlanPosture.ask` becomes the single vocabulary. The deny
paths keep their distinct `decidedBy` markers for audit — those are
orthogonal to answerability and unchanged.

**3. Provenance in the plan store, mirroring the tool side.**
`PlanApproval.approved` gains a companion, not a new enum value — the
approval *dimension* stays a four-value machine, but `Plan` records *who*
settled it:

```dart
enum PlanGrantSource { user, auto }   // default: user
```

`PlanStore.approve` takes an optional source (the `/plan` command and the
overlay pass user; `PlanTool`'s auto-grant passes auto); the strip and
overlay badge gain a quiet `· auto` suffix for auto grants; the manifest
blob persists it (`plan_store.dart:45` already serializes `approval.name`).

**4. Shape of the door (the part this proposal does NOT build yet).**
`PlanPosture` is a constructor argument, not a scope service — the minimal
correction to PR #61. The full door is a read-only scope key (say
`postureQueryServiceKey`) that any plugin may `lookup`, backed by core, so
the next posture consumer does not need a core wiring change at all. That
follows the same "scope provides, core decides" pattern the plan store
itself already uses (`plan_ui.dart:13-34`), and is the natural follow-up
once one consumer proves the shape.

## Migration

1. Add `PlanPosture` + core minting; keep `resolveApprovalMode` but have it
   delegate to the handed posture (deprecation note in its doc comment).
2. Switch `PlanTool`/`PlanMiddleware` constructors to take `PlanPosture`
   (breaking only to direct constructors — tests and the one call site in
   `agent_composition.dart`).
3. Add `PlanGrantSource`; thread through store, command, overlay, strip,
   manifest; render the `· auto` suffix.
4. Only after (1)–(3) settle: introduce the scope-key door for the *next*
   consumer. Do not widen the door for plugins that have not asked.

## Alternatives considered

- **Leave it: the plugin reads policy/host directly (status quo).** Rejected
  as the settled shape — it works today, but every posture nuance must now
  be maintained in two places, and §11's boundary becomes unenforceable in
  practice (nothing marks `resolveApprovalMode` as a boundary violation; a
  reviewer has to notice).
- **Move `resolveApprovalMode` into core (`agent_composition.dart`), keep
  the result a parameter.** Cheapest possible fix, and step 1 is nearly
  this — but parking a bare `PlanApprovalMode` in core keeps the policy
  semantics in a plan-specific enum, which the notification-plugin case
  cannot reuse. Minting a posture *value* in core is the same cost now and
  generalizes.
- **Give plugins the whole `PermissionPolicy`.** Rejected: it hands plugins
  a mutable, rule-carrying object (`policy.check` is a decision surface,
  not a fact); the door must be read-only and coarse.

## Acceptance

- No plugin file references `policy.allowAllByDefault` or
  `host.canAnswerQuestions` directly (grep-verifiable).
- A `plan_approval_gate_test.dart` case for each: mode nuance added to core
  changes the plan gate with **no** plugin edit (the drift demo, inverted);
  an auto grant round-trips a session manifest and comes back as
  `approval: approved, source: auto`; the strip/overlay show the auto
  mark.
- All existing gate tests (`plan_approval_gate_test.dart`) keep passing
  with the same expectations — behaviour is unchanged; only the ownership
  moves.
- `resolveApprovalMode` is gone or a pure delegation.
