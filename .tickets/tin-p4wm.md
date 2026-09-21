---
id: tin-p4wm
status: open
deps: []
links: [tin-y9k2]
created: 2026-09-21
type: hardening
priority: 1
assignee: Nick Fisher
tags: [permissions, sandbox, capabilities, classifier]
---

# Permission hardening: the gaps the sweep cannot see

## Context

The audited bypass classes are closed and made structural. Tools declare
`ToolCapabilities` (reads / writes / spawns / network / indirect); the policy
**derives** both its default decision table and the read-only boundary from
those declarations, with the worst case for anything undeclared; argv is built
through `FencedArguments` so a model value cannot reach an option region; and
every spawning tool takes the framework's shared runner via `SpawnsProcess`.

Two sweeps fail CI on a regression: a structural one over the engine's mounted
registry and the application's interactive mount (declaration completeness,
"escapes the sandbox ⇒ needs a `reviewed:` reason", runner identity), and a
behavioural argv sweep that drives every spawning tool with hostile input. Both
have been verified by falsification — restoring the old `grep` argument list, or
auto-approving `fetch`, fails them.

Three gaps remain, two of them things the sweep literally cannot see.

## 1. `write_summary` spawns outside the framework

`WriteSummaryTool` runs `Process.runSync('git', …)`
(`write_summary_tool.dart:137`) with fixed internal arguments, so there is no
injection risk — but it is unconfined, and it takes its own `IoFileSystem`.
It is mounted by a separate plugin (`_writeSummaryPlugin`), **not** in the base
registry, so the capability sweep never sees it: its `spawns: fixed`
declaration is currently unchecked and the runner invariant does not cover it.

Fix: inject a `ProcessRunner` from the plugin (`caps.processRunner`), implement
`SpawnsProcess`, make the git helper async, and get the tool into the sweep's
mounted set so the invariant applies. Add a per-tool argv/runner test as `grep`
and `git` have.

## 2. `explore_project` is read-only but deliberately undeclared

Mounted by the application when the orchestrator wires the explorer. Today it
is `ask` by default in every mode, yet permitted in `readAll` — quirky but
current behaviour, preserved by a one-entry allowance
(`PermissionPolicy._readOnlyButUndeclared`) and mirrored in the app-side sweep's
`notYetDeclared`.

The blocker is that declaring it a project read derives an `allow` **default**,
flipping it from `ask` — a posture change that needs a decision rather than
arriving as a side effect of removing a list. Decide, then delete both entries.

## 3. `/spawn` and `/branch` drop the user's configured rules

Verified at `conversation_operations.dart:176-196`. The spawned conversation's
policy is built from the profile's tool names only:

- `configuredPolicy.staticRules` is not carried forward, so `--deny 'fetch:*'`
  (or any rule for a tool other than bash/exec) is silently not enforced;
- every profile tool becomes an `allow` rule, so `fetch`/`web_search` and the
  rest are auto-approved in the side conversation.

A `commandPolicy` carrying the configured rules is built but consulted only for
`bash`/`exec`. Fix: carry `staticRules` into the new policy and keep network
tools at the parent's decision, the way the sub-agent path now does with
`_neverPreApproved`.

## Adjacent, from the same audit — separate decision, not this objective

- **`LocalControlTool` bypasses `check()`.** Verified at
  `tool_executor.dart:422-424`: the decision is hardcoded `allow`, so a `--deny`
  naming `begin_environment_execution` is inert rather than enforced. Narrow —
  the sole implementor only flips a stage flag, so there is no escalation.
- **The auto-mode classifier parse.** `classifier.dart:71` tests
  `contains('ALLOW')` *before* `contains('DENY')`, so "I cannot allow this.
  DENY", "not allowed" and even "DISALLOW" all **grant**. The judge is also fed
  raw tool input with no "this is untrusted data" framing, and its verdict is
  remembered for the session (`mode_aware_asker.dart:39-42`). Agreed direction:
  a forced tool call with an enum verdict (`allow` / `deny` / `unsure`), a
  strict fallback that never substring-matches, and a third answer that routes
  genuine uncertainty to the user instead of a silent, sticky deny.

## Verification expected

`dart analyze` clean on each changed package; `tina_engine`, `tina_index`,
`tina_app` and root suites green. Item 3 should come with a test asserting a
`--deny` rule survives `/spawn`.
