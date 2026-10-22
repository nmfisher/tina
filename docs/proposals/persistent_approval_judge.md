# The persistent approval judge — state, history, context, and a line to the user

Status: **proposed**. Everything through "What ships today" describes code
that ships now; every claim in it was checked in the source at `225fcfb0`
and file:line is cited. Everything from "The gap" on is a proposal.
Date: 2026-10-06.

## Summary

In auto mode, every command and write that the deterministic layers cannot
quietly allow goes to one classifier: `PermissionClassifier`
(`packages/classification/lib/permissions.dart:42`). It is a **stateless
one-shot**: a fresh provider per call, one JSON evidence document, a fixed
system prompt, a single structured reply, and the provider closed. It
remembers nothing. Its only memory is precedents other people recorded —
evidence injected into the payload, never lessons it drew itself
(permissions.dart:102-108).

This proposal makes the judge a **persistent agent** with the four
properties that phrase implies:

1. **State** — its own durable store (workspace-scoped, JSONL, same shape
   as precedents) that survives restarts.
2. **History** — its own past verdicts and what happened after them,
   readable and reflectable-upon, not just a per-call payload.
3. **Context** — a rolling summary of the session it is judging inside,
   and the ability to hold a multi-turn dialogue for hard cases instead of
   answering from one prompt.
4. **A line to the user** — the ability to *ask* the user through the
   existing approvals channel when its own confidence is low, instead of
   the current all-or-nothing fallback (answer alone, or bounce the whole
   request to the human with no judge participation).

The boundary does not move: the judge **recommends**, `ModePlugin`
decides, and only a human answer grants remembered scope. Yolo, the kernel
jail, the writable-directories gate, and the precedent fast path are all
untouched. Migration is six small steps, each shippable alone; the first
two change no behavior visible to the model.

## Terms

- The **judge** is `PermissionClassifier` plus the instruction and
  precedent evidence wired around it (`apps/tina_cli/lib/src/plugin_catalog.dart:246-250`).
- A **verdict** is one ALLOW/DENY (or failure) the judge returned.
- The judge's **memory** is everything it can consult that outlives one
  `classify` call: precedents today, the proposed store tomorrow.
- The judge's **line to the user** is a question the judge itself poses
  through the approvals channel, marked as judge-asked.

## What ships today

The life of one ask in auto mode, all inside `ModePlugin.request`
(`packages/plugins/tina_mode/lib/tina_mode.dart:241`):

1. The gate (`decideCommand`/`decideOperation`) says **ask**, or a
   `humanOnly` path (network, directory grants, outside-sandbox) forces
   the question.
2. Yolo short-circuits everything at the top (tina_mode.dart:253-257);
   irrelevant here but worth restating: no proposal in this document
   changes yolo.
3. Evidence is assembled once: operation, target, reason, the caller's
   context, `user_request` (the turn's input text), the tool call, and
   `recent_context` — the conversation tail plus recent tool calls with
   their outcomes (tina_mode.dart:281-295, 485, 525).
4. **Precedent fast path**: an exact read-only shape the user approved
   twice runs without any model round trip (tina_mode.dart:301-307).
5. Otherwise the judge classifies: precedents are merged into the payload
   as evidence (permissions.dart:100-109), the fixed system prompt — the
   safety rules, scope rules, precedent rules — is sent, and one JSON
   verdict comes back, validated hard (permissions.dart:335-365). One
   retry for a malformed verdict; timeout and cancellation cover both.
6. On ALLOW, `ModePlugin` allows once — never a session grant, never
   remembered scope (tina_mode.dart:323-336). On DENY or failure, the
   whole request falls through to the human with a one-line
   `auto_approval_fallback` sentence and the judge's deny reason attached
   (tina_mode.dart:337-345, 403-405).

Where state lives: `FilePrecedentStore`, JSONL, atomic temp-file rename,
cap 512, per workspace under `<config dir>/precedents/<workspace>.jsonl`
(`packages/classification/lib/src/permissions/precedent_store.dart:97-171`,
wired at plugin_catalog.dart:241-243). Precedents record outcome, authority
(humanAlways / humanOnce / classifier), and coverage
(`precedent.dart:12-16,280`), and are retrieved by field-weighted
similarity, with a deny outranking an allow at equal similarity
(precedent.dart:440-500). The user's instruction text rides along from a
settings key (plugin_catalog.dart:248-249).

What the judge is not: it holds no fields but a provider factory, a
timeout, and two read callbacks (permissions.dart:43-56). It cannot see a
previous verdict it made this session except as precedent evidence. It
cannot ask anyone anything. It has no notion of "the last three times I
saw this pattern I said ALLOW and the user overrode me once."

## The gap, property by property

**State.** The judge's judgments evaporate. The only durable trace is the
precedent `ModePlugin` records after the fact — keyed by request shape,
not by the judge's reasoning. Nothing records *why* a verdict was hard,
what evidence was missing, or what the user's override said about the
judge's call.

**History.** Within a session the judge sees one request at a time. A
series of related asks — the agent iterating on a failing build command —
is judged as if each were the first. The prompt's `recent_context` helps
(permissions.dart:177-183) but is assembled by the caller per request, not
accumulated by the judge.

**Context.** The judge cannot deliberate. When evidence is ambiguous — an
unrecognized script, a path that might be generated — its only options are
instant DENY ("When uncertain, DENY", permissions.dart:199) or a bounce to
the human that carries none of its thinking. There is no second turn, no
"let me look at that file," no clarifying question.

**The line to the user.** Inverted today: when the judge is unsure, the
*request* goes to the human and the judge goes silent. The judge never
formulates the question, so the human answers blind: the fallback reason
is generic ("classifier recommends denial: …"), and the ask dialog shows
the caller's reason, not what the judge actually wanted to know. The
rich `ApprovalDecision` vocabulary the channel already has —
`allowAlways`, `allowWorkspace`, directory grants
(`packages/plugins/tina_approvals/lib/tina_approvals.dart:14-24`) — is
invisible to the judge.

## The design

### 1. JudgeStateStore — state

A per-workspace JSONL store beside the precedent store:
`<config dir>/judge/<workspace>.jsonl`. Same discipline as
`FilePrecedentStore`: append-only lines, atomic rewrite on compaction,
cap-bounded, corrupt lines skipped, `Memory` twin for tests
(precedent_store.dart:33-90 is the template).

One line per judged request, appended by `ModePlugin` (which already knows
the outcome):

```
{ id, at, evidence_digest, verdict: {allow, reason, coverage},
  question: "what made this hard", // judge-supplied, optional
  outcome: {human_decision|null, applied: bool, user_overrode: bool},
  session_id }
```

No secrets: paths and operation kinds only, never command arguments or
file contents — the same rule the precedent store and the deny-reason
sanitizer already follow (permissions.dart:153-155, 345-352).

This is step 1 of the migration and changes no behavior.

### 2. JudgeMemory — history

A pure module over the store (mirror `precedent.dart`'s split: pure
ranking, thin store). At classify time `ModePlugin` passes a ranked,
bounded digest the judge reads like precedent evidence:

- **rules**: short durable lessons — "user's release flow writes outside
  the workspace; external dirs named in the task are in scope" — extracted
  by reflection (below), each with a confidence and a creation date.
- **outcomes**: the last N verdicts on similar requests and what happened
  — especially `user_overrode: true`, which is the loudest calibration
  signal the system has.
- **summary**: a rolling paragraph of the current session's judged
  history ("this session: 14 asks, 11 allowed routine build/test; the 3
  hard ones were all network egress to npm").

Bounded like precedents (≤ 512 lines, digests ≤ a few KB) so the payload
cannot balloon.

### 3. Deliberation — context

Two mechanisms, both behind the existing classify seam so `ModePlugin`
routing is untouched:

- **A richer reply.** The verdict schema grows an optional
  `need_more_information: {question, kind}` where `kind` ∈
  {`ask_user`, `read_paths`} plus, for `read_paths`, explicit paths. If
  present, `ModePlugin` re-enters classify once with the requested
  material appended to the evidence. Maximum one extra round per request;
  the second reply must be a verdict or the request falls through to the
  human exactly as today (fail-closed, and the existing fallback reason
  codes at tina_mode.dart:362-363 already cover the bounce).
- **A real dialogue, later.** The batch protocol in
  `packages/classification/lib/src/judgments/models.dart` —
  `JudgmentRequest` with a reusable `state` and typed multi-question
  answers — was built for exactly this shape and is currently unused by
  the judge. Migrating the judge onto it turns the single prompt into a
  conversation whose transcript is the `state`. Defer until the richer
  reply has proven the demand; do not build both at once.

Read access for the judge (`read_paths`) stays inside the sandbox's
read rules and the existing protected-path exclusions — the same file
tools, the same `SandboxedFileSystem`, just invoked from the judge loop.
Paths the plan cannot read are returned as unresolved, and "unresolved"
never becomes ALLOW (permissions.dart:144-146 already words this for the
single-shot prompt; it carries over).

### 4. The line to the user

A new ask kind on the existing channel. When the judge returns
`need_more_information: {kind: ask_user, question}`, `ModePlugin` calls
`approvals.request` with:

- `kind: ApprovalKind.confirmation` — a judge ask can never return
  remembered scope. The `onCommandPattern` / `onDirectoryGrants`
  callbacks stay wired only to human-initiated permission requests
  (`tina_approvals.dart:47-59`); a judge ask's possible answers are
  allow-once / deny / "stop asking me, decide yourself" (which routes
  back to the human permission ask with the judge's question attached).
- The dialog shows **the judge's question** plus the standard
  request details, and is marked judge-asked in `details` so UIs can
  render it differently and audits can tell it apart.

Timeout policy: a judge ask that expires is **the judge's own deny** —
the request then falls through to the normal human permission ask, which
has no deadline by default (`tina_approvals.dart:111`). A judge ask can
therefore never be the thing that fails open. Transport and parking ride
the same rails as human asks; `docs/proposals/remote_answerable_approvals.md`
is the plan for answering asks without a terminal, and judge asks are
just one more ask kind on top of it — no new ingress mechanism.

Every judge ask and its answer is appended to the store — including the
denials, because a judged deny that the human then approves is the exact
case where the judge needs to update its rules.

### 5. Reflection — turning history into rules

After each turn (or on a bounded cadence), an async pass — same pattern as
the existing `tina/classification` plugin's background work — reads the
session's new store lines and asks the model to propose, revise, or retire
**rules** with evidence citations. Rules are small, capped, and versioned;
a rule that produced an override is flagged. Reflection never runs
mid-turn, never grants anything, and its output is evidence for the next
verdict, nothing more.

Budget: reflection is one bounded call per turn at most, skipped on
failure, and suppressed entirely when the store gained no new lines.

### 6. Calibration — keeping the judge honest

The store makes three cheap checks possible, reported in the existing
diagnostics fields (`PermissionJudgment.diagnostics`):

- **override rate** per rule and overall. A rule the user keeps
  overriding is auto-retired to evidence-only.
- **ask rate**: how often the judge bounces vs decides. Deliberation
  should lower bounces without raising overrides; if it lowers bounces by
  raising wrong-allows, that is visible immediately.
- **drift guard**: if a session's override rate crosses a threshold,
  `ModePlugin` drops to always-ask for the rest of the session (fail
  closed) and says so in the terminal line it already prints for
  fallbacks (tina_mode.dart:345).

## What deliberately does not change

- **Yolo** — untouched, still the unconditional bypass (tina_mode.dart:253-257).
- **The kernel jail and the gate** — the judge is advisory above them;
  `OsSandboxRunner` and `decideCommand` behave exactly as today.
- **The precedent fast path** — deterministic, cheap, and already good;
  it stays ahead of the judge in the routing.
- **Plugins never decide** — the decided boundary from the earlier
  proposal this builds on (`remote_answerable_approvals.md`, preamble):
  surfaces deliver answers, the mode policy owns routing, humans own
  remembered scope. The judge gains a voice, not a vote.
- **The stateless path survives** — every new capability degrades to
  today's behavior: no store ⇒ no rules, no reflection; provider without
  the richer reply ⇒ single-shot; judge ask unanswered ⇒ normal fallback.
  Embedders that supply their own `PermissionClassifier` (the constructor
  is public and tested against fakes) keep working unchanged.

## Migration order

1. **Store + record** — JudgeStateStore, appended on every auto-mode
   resolution. No behavior change. Tests: store round-trip, corruption
   tolerance, cap eviction, secrets never written.
2. **Read memory** — JudgeMemory digest into the existing payload.
   Behavior change is only in what the judge knows. Tests: digest
   bounding, ranking, golden payload.
3. **Richer reply** — `need_more_information` with one extra round.
   Tests: one-round-only enforcement, fallback on second failure,
   cancellation mid-deliberation.
4. **Judge asks** — `ask_user` over the approvals channel with
   confirm-only semantics and timeout-deny. Tests: no remembered scope
   from a judge ask, timeout falls through to human ask, audit lines.
5. **Reflection** — the rules pass. Tests: rule extraction is
   evidence-cited, override retires a rule, budget respected.
6. **Calibration + drift guard** — diagnostics and the always-ask
   breaker. Tests: threshold math, breaker latch and message.

Steps 1–2 are one reviewable PR each; 3–4 are where design review should
focus; 5–6 can follow once real usage data exists in stores.

## Alternatives considered

- **Keep stateless, invest in precedents only.** Cheapest, but precedents
  are shape-keyed and human-sourced; they cannot capture "the build
  command changed and the new one is fine," cannot deliberate, and cannot
  ask. This proposal keeps precedents and layers judgment on top.
- **Use the batch judgments API today** (models.dart, `JudgmentRequest`).
  The right destination for the dialogue form, but adopting it in step 1
  couples the store work to a protocol migration. Deferred to its own step.
- **A small local model as the judge.** Fast and private, but the judge's
  value is careful reasoning over novel requests — exactly what small
  local models are worst at. Not pursued.
- **Make the judge the approver** (its allow grants remembered scope).
  Rejected: it collapses the human/authority boundary the approvals
  design settled, and precedent authority already distinguishes
  `humanAlways` from `classifier` for exactly this reason
  (precedent.dart:16). Classifier approvals remain apply-once.

## Acceptance

- A restarted session's judge recognizes rules it learned last session
  and cites them in a verdict reason.
- A denied request that the user then approves produces, by the next
  session, either a revised rule or a flagged override — visible in the
  store.
- A judge ask times out with no human present and the request lands in
  the normal human ask queue; nothing is granted.
- Override rate and ask rate appear in diagnostics for every verdict.
- With the store deleted mid-session, the judge degrades to today's
  behavior with no error surfaced to the model.
- Existing `PermissionClassifier` consumers (tests, embedders) compile
  and pass unchanged.

## Open questions

1. Where judge asks appear in the TUI — same modal as permission asks
   with a marker, or a separate surface? (The approvals TUI plugin owns
   presentation; the protocol here is channel-neutral.)
2. Should rules be user-visible and user-editable (a `/rules` command),
   or read-only evidence? Editable implies trusting user-authored text
   injected into the judge prompt — the sanitizer rules would need to
   cover it.
3. Does the reflection pass earn its keep at one call per turn, or should
   it be session-end only until stores show otherwise?
4. Cross-workspace rules: the store is workspace-scoped like precedents;
   is a global rules tier ever wanted, or is per-workspace the right
   permanent scope?
