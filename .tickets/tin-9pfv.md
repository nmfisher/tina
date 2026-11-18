---
id: tin-9pfv
status: open
deps: []
links: [tin-p4wm]
created: 2026-10-01T09:00:00Z
type: feature
priority: 1
assignee: Nick Fisher
tags: [profiles, settings, cli, tui]
---

# Model profiles + settings/cruft cleanup (commits 21+ on asb/profiles)

## Context

Rolling-memory program (issue 94) is on main, CI green. This ticket
implements owner-approved **model profiles** plus a settings/cruft
cleanup, including removing `/spawn` (owner directive; also flagged in
tin-p4wm item 3). Brief: /tmp/profiles_brief.md.

## Proposal

A **profile** bundles three legs — main (conversation), subagent
(`launch_subagent` children), approver (permission classifier +
command-pattern suggester, renamed from "judge") — each a
provider+model pair. Config gains `profile:` (active) + `profiles:`
map. Omitted leg inherits main; omitted provider inherits session
provider; one-line profiles valid. Legacy config with no `profiles:`
synthesizes a `default` profile from `model:` + `providerId:` —
identical behavior on fresh checkouts, nothing nags. Wire validation
per leg at profile load; failures name profile and leg.

Resolution: main = active profile main leg (`/model` overrides per
session, re-points future requests only); subagent = active profile
subagent leg, unset → inherit parent's current model+provider at
spawn; approver = active profile approver leg, unset → legacy
`classifierModelSetting` → conversation model. Child factory gets the
profile value; running children keep what they started with.
Per-provider effort/budget/max-output unchanged.

TUI: three legs as model-picker rows via existing `ModelSettingEditor`;
profile picker in connection controls; `/profile [name]` switch/list.
Switching copies profile legs into current values (profiles are
presets, legs are the truth). `/model` preserved verbatim. `/spawn`
removed; docs state new conversations start by launching tina or
--resume/--continue. Keep `/close`, panel inventory, `createSession`
(initial-session path).

CLI: `--profile NAME` launch switch; `--configure` gains profiles
section; `--model` unchanged; `--models` may list profiles.

Cruft sweep: classifierModelSetting + classifier timeout/instruction
consolidate into the profiles module (old setting deprecated in
description, one-release lifetime); inventory every
SettingDefinition across packages, unreferenced ones deleted with
rationale listed before the removal commit; consolidate duplicated
model lists between TUI editor and connection controls.

Layers (one commit each): 21 config+resolution+migration+tests,
22 subagent leg, 23 approver leg, 24 /spawn removal, 25 TUI wiring,
26 CLI switches, 27 cruft inventory+removal+docs.

## Acceptance

- Analyzer clean; all suites green; repository tools + architecture
  guard green; policy.json registrations for new files.
- Live transcript: `/profile budget` → subagent spawned on subagent
  leg → judge denial surfaced → `/model` override → `/profile` back;
  legacy config synthesizes default profile; `--profile budget`
  launch switch works.
- Commit locally only; never push/merge; no pkill/killall; no
  update_plan; no approval asks; no secrets.

## Log

- Prep: merged origin/main (up to date at 3ec52eb3); submodule
  dart_notcurses initialized; repository pub-get flow green; ticket
  filed.
