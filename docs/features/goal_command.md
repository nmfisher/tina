# The /goal command

`/goal` sets a per-conversation session goal — the thing this conversation is
supposed to achieve. A judge reviews the transcript after every goal-active
turn and announces when the goal is achieved. The feature mirrors the plan
tracker's shape: a store service, a middleware that keeps the model aware, a
status-strip source, and a plugin-contributed command.

The default execution profile mounts `goalUiPlugin(store: GoalStore())` in
`bin/tina.dart`; `buildAgent` mints a per-conversation `GoalMiddleware` when
the `tina.goal` service is present. The store is in-memory, like `PlanStore`,
but both trackers persist: `TrackerPersistence`
(`packages/tina_app/lib/src/persistence/tracker_persistence.dart`) hooks every
goal/plan mutation into the session manifest so a `/resume` or restart restores
them (see "Tracker persistence" below).

## Store

`GoalStore` (`packages/tina_app/lib/src/goals/goal_store.dart`) keeps one
`Goal` (text + optional `GoalStatus`) per conversation id.

- `set(id, text)` trims and validates (max 500 chars, non-empty), and resets
  any previous verdict — a new goal is not yet judged, and the old verdict
  must not leak onto it.
- `recordVerdict(id, verdict, evidence)` stores a `GoalStatus` (evidence
  capped at 240 chars) and fires the broadcast `changes` stream only when the
  verdict actually changed; a judge that re-states its last verdict produces
  no event, so the strip never churns. Throws `StateError` when the goal was
  cleared while the judge was running.
- `clear(id)` removes the goal and fires only when something existed.
- `judgeHook` is a late-bound hook (`GoalJudgeHook`): the coordinator installs
  it after composition, once the scheduler and conversations exist. `/goal
  check` reads it at dispatch time, so a session without a wired judge fails
  cleanly instead of at startup.

## Command

`goalCommand` (`goal_plugin.dart`) contributes `/goal` (help order 46):

| form | effect |
|------|--------|
| `/goal <text>` | sets the goal (resets the verdict) and echoes it |
| `/goal` / `/goal status` | shows the current goal and last verdict |
| `/goal check` | runs the judge now, with `force: true` |
| `/goal clear` | removes the goal |

Without an argument the command shows; free text sets. `/goal check` without
a goal or without a wired judge reports and returns `CmdHandled(failed: true)`.

## Judge

`judgeGoal` (`goal_judge.dart`) is the one-shot verdict path, driven through
the store's `judgeHook`:

1. Digest the conversation history (`GoalJudgeDigest`): the last 24 messages,
   user and assistant text verbatim, tool activity as compact `tool: name`
   markers, every line — prefixes included — counted against a 12000-char
   budget with a 2400-char per-block cap.
2. Run a single read-only agent call through the scheduler (`runStandalone`):
   no tools, no panel, no session, output swallowed by a `_SilentSink`. The
   model answers one `VERDICT: <yes|no|unclear> — evidence` line, which is
   parsed leniently (dash variants, case-insensitive, missing evidence
   tolerated).
3. Record the verdict and announce **transitions only** in the transcript:
   `achieved` as an info notice, `uncertain` as a warning with the re-check
   hint. `inProgress` and `none` stay silent — "still working" is the default
   state and would spam every turn. A repeated verdict never re-notifies.

Failure is fail-closed and never throws: an unwired hook, an empty goal, a
missing conversation, an unparseable answer, or a failed call leaves the
previous status untouched and returns null. An **aborted** turn is skipped
unless `force` is set — a budget trip or provider error is not evidence of
progress or failure.

The turn trigger lives in the TUI coordinator: on a completed turn with a
non-empty goal it fires the judge as an unawaited continuation, rooted in
`Zone.root` (the parent invocation is already done when the continuation
runs, and the standalone runner rejects a done parent).

## Rendering

`GoalStatusSource` exposes a `GoalSummary` (goal text, verdict, evidence)
whenever a goal exists; the strip renderer (`lib/tui/goal_status_renderer.dart`)
prefixes `✓` for achieved and `?` for uncertain. `GoalMiddleware` appends a
`<current-goal>` section to the system prompt at the request stage — the goal
text plus verdict guidance — so the model keeps working toward a goal it
cannot see in scrollback.

## Tracker persistence

`ConversationMeta` carries two opaque app-owned blobs — `goal` and `plan` —
that the engine never parses (same precedent as `policy`). The wiring:

- **persist** — `TrackerPersistence.install` hooks `GoalStore.persistHook` and
  `PlanStore.persistHook`. Every mutation (set, verdict, clear, plan update,
  approval change) re-writes BOTH blobs through
  `SessionStore.updateConversationTrackers` — null clears one field while the
  other survives. Before each write the binder calls the host's
  `ensureRegisteredFor` (the conversation's recorder), so a goal set ahead of
  the transcript's first append still lands in a manifest a later `--resume`
  can see. Writes are serialized on a chain and are best-effort: failures are
  logged and swallowed, mirroring the spend ledger's flush.
- **hydrate** — the coordinator calls `controller.hydrateTrackers(metas)` once
  at startup, and `resumeIntoActive` re-hydrates the resumed conversation
  (keyed by the live conversation id, blobs read from the manifest's active
  conversation — they differ only under legacy re-keying). The manifest is
  authoritative: an absent blob clears stale in-memory state. Hydration
  sanitizes leniently (`Goal.fromJson`/`Plan.fromJson` re-apply every cap and
  invariant) and never writes back. Headless runs hydrate before command
  dispatch and catch up any dispatch-window mutation with
  `persistIfPresent` once the recorder exists.

## Tests

- `packages/tina_app/test/goals/goal_store_test.dart` — validation, verdict
  reset on set, evidence cap, dedupe, the clear race, JSON round-trip +
  hydrate.
- `packages/tina_app/test/goals/goal_judge_test.dart` — digest caps, verdict
  parsing, transition-only announcements, abort skip, fail-closed paths.
- `packages/tina_app/test/persistence/tracker_persistence_test.dart` — paired
  blob writes, ensure-before-write ordering, authoritative hydrate, swallowed
  failures.
- `test/session_controller_test.dart` (`goal/plan persistence across /resume`)
  — mutations land in the manifest; resume/startup hydration restores and
  clears; shutdown drains the write.
- `test/composition/goal_ui_plugin_test.dart` — plugin activation, command
  dispatch, middleware injection, status source.
