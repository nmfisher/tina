---
id: tin-b3xa
status: closed
deps: []
links: [tin-3i3l]
created: 2026-11-11T03:48:48Z
type: feature
priority: 1
assignee: Nick Fisher
tags: [permissions, sandbox, approvals, containment]
---

# Box-model permissions — replace prediction with containment (Stage A)

## Context

The current approval stack predicts command behavior (classifier, effect
assessments, precedents, pattern grants, three grant scopes, five modes).
The owner finds it too complex and too prompt-heavy. Agreed direction:
stop predicting, start containing — three boxes, one list:

1. Read-only in the workspace → run, never ask.
2. Writes/network inside an allowed scope → OS sandbox profile fitted to
   the command family. Silent.
3. Needs something no box provides → ask, with a persistent glob
   allowlist option (project + global file, no triple scope).

Stage A lands the box model as a parallel decision path behind an opt-in;
the classifier/modes stack and its tests stay untouched and green.

## Proposal

1. Sorter: pure `command → box` function reusing the shell parsing in
   `sandboxed_process_runner.dart` / `read_only_commands.dart`; returns
   box + suggested sandbox profile; unknown constructs fall to box 3.
2. Named sandbox profiles as data: `scripts`, `build`, `packages`,
   `default` — mapped onto what `os_sandbox_runner.dart` (bwrap) supports.
3. Silent path for boxes 1–2; box 2 reports allowances at end of turn.
4. Box 3 asks via the existing approval dialog, gains "always allow this
   pattern" storing a glob in a new plain, versioned, user-editable
   allowlist file; stored patterns name the box/profile future matches
   run in.
5. Wiring behind one opt-in that fits the existing mode plumbing with
   least churn. Native CLI only; wasm path and `asking_boundary.dart`
   untouched.

## Acceptance

- `dart analyze` zero issues on every touched package.
- New unit tests: sorter table, profile → sandbox args mapping,
  allowlist pattern matching.
- Existing suites green: `tool/repository`, `tina_core`, `tina_tools`,
  `tina_mode`, CLI tests. Opt-in keeps any behavior change off by
  default; no test edits.
- Real-run transcript through the new path (python script, dart test,
  network command) captured from the container.
- Design note `docs/sandbox_boxes.md`; small local commits on
  `asb/perm-boxes`; no merge, no main, no push.

## Progress

- Started 2026-11-11. `tk` not installed in this container (same as
  tin-r6km/tin-h8uw/tin-vb4k); status changes land as frontmatter edits
  here.
- Repo prep done (submodule is `packages/dart_notcurses`, not `dart_notcurse`;
  pub get via tool/repository resolve_owned). Design surveyed: gate
  (`sandboxed_process_runner`), jail (`os_sandbox_runner` + `buildBwrapArguments`),
  decision pipeline, ModePlugin ask routing, settings library.
- Plan: opt-in via settings key `tina/tools/permission_boxes` (least churn —
  a PermissionMode value would ripple through /mode cycling, prompt sections
  and the decision pipeline; a CLI flag cannot be reviewed/persisted). New
  `box_model.dart` (boxes, profile specs, gate), `box_sorter.dart` (pure
  sorter over the literal shell parser + family tables), `box_allowlist.dart`
  (plain v1 text file, project + global). Box 3 asks through the existing
  dialog; its existing "edit command pattern" answer stores to the new
  allowlist when the opt-in is on (no new ApprovalDecision value — least
  churn; documented as a deviation).
- Container has no bwrap and user namespaces are blocked: the live-run
  transcript will show real passThrough behavior plus a confined-runner
  harness for the silent path.
- DONE (commits 76120058, b8bbcbe0 on `asb/perm-boxes`): box_model.dart
  (boxes, 4 profile specs, profile→bwrap mapping, setting),
  box_sorter.dart (pure sorter, heredoc support, destructive/allowlist/
  visible-world rules), box_allowlist.dart (v1 plain files, project +
  global, glob dialect + dialog-regex translation), box_gate.dart (silent
  box 1/2 execution, end-of-turn report batch), runner hook + ToolsPlugin
  wiring + approval_plugin pattern redirect, CLI setting registration,
  docs/sandbox_boxes.md.
- Verification: analyze clean on tina_tools/tina_mode/tina_core/tina_cli/
  tool/repository; 59 new box tests green; tina_tools/tina_mode/tina_core/
  tool/repository suites match the pre-change baseline exactly (22-29
  failures identical on HEAD~1 and HEAD — all environmental: this
  container has no confinement backend and no notcurses TTY; diffed
  twice); CLI deterministic subset identical to baseline.
- Live transcript captured (live-boxes tag): sorter verdicts correct for
  python script (2/scripts), dart test (2/build), curl (3); all three
  correctly declined the silent path without a backend and asked through
  the existing dialog; fail-closed held (nothing ran, no outside write).
  Allowlist ask→pattern→file→rule round-trip verified end-to-end
  (box_allowlist_flow_test). Closed 2026-11-11.
