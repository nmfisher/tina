---
id: tin-y0l0
status: open
deps: []
links: []
created: 2026-09-11T10:00:00Z
type: bug
priority: 2
assignee: Nick Fisher
tags: [permissions, config, headless, tools]
---
# `--yolo` restricts tools it should not, and its refusal message tells you to use `--yolo`

## Context

Found while driving a tina-only sandbox run on tin-r6km (PR #49) with
`tina --yolo`. Mid-run, a `glob` call was refused and the run lost a step:

```
glob:
  refused (use --allow "glob:*" or --yolo)
glob denied
```

The advice is circular: `--yolo` was already passed on the command line.

## Root cause

`RuntimeConfig.buildPolicy()` (`packages/tina_app/lib/src/config/runtime_config.dart:202`)
builds the yolo defaults as a **four-entry map**:

```dart
final defaults = yolo
    ? {
        'read': PermissionDecision.allow,
        'write': PermissionDecision.allow,
        'edit': PermissionDecision.allow,
        'bash': PermissionDecision.allow,
      }
    : null;
```

That map **replaces** the policy's own default table rather than widening it.
`PermissionPolicy.check()` ends with:

```dart
return _widen(tool, defaults[tool] ?? PermissionDecision.ask);
```

so every tool **absent** from the replacement map falls through to `ask`.

The policy's built-in table (`packages/tina_engine/lib/src/permissions/policy.dart:99-118`)
defaults these to `allow`: `read`, `search`, `grep`, `glob`, `ls`, `stat`,
`which`, `write_summary`, `git`. Only `read` survives into the yolo map.

Two consequences:

1. **`--yolo` makes several read-only tools stricter than the default.** `glob`,
   `search`, `grep`, `ls`, `stat`, `which` are `allow` by default but become
   `ask` under `--yolo`. It also drags `fetch` and `web_search` (normally `ask`)
   in the same way, plus any tool not named in the four-entry map.
2. **In a headless run those asks become hard refusals.** `HeadlessHost.askPermission`
   auto-denies, so the tool is simply unavailable — and it prints the misleading
   "use --yolo" hint.

The `--yolo` help text promises the opposite: "Default every tool to allow
(skip all permission prompts). Explicit --deny rules still apply."
`headless_host.dart:16` also states the intent that allow/yolo rules "decide
before the asker is ever reached".

## Observed in the wild

Live evidence from tina-driven sandbox runs on PR #49, all launched with
`tina --yolo --backend notcurses --prompt ...`:

```
glob:
  refused (use --allow "glob:*" or --yolo)
glob denied
```
```
ls:
  refused (use --allow "ls:*" or --yolo)
  ls denied
Grep and ls are blocked. I'll read the likely files directly
```
```
grep:
  refused (use --allow "grep:*" or --yolo)
  grep denied
```
```
git:
  refused (use --allow "git:*" or --yolo)
  git denied
```

So four tools that are `allow` **by default** are denied under `--yolo`:
`glob`, `ls`, `grep`, `git`. The agent loses its file-discovery and version
control tools and has to fall back to reading files directly.

## Repro

Headless run with an auto-refusing asker:

```
tina --yolo --backend notcurses --prompt 'list dart files with the glob tool'
```

Observed: `glob: refused (use --allow "glob:*" or --yolo)`, tool denied.
The same refusal appears for `ls`, `grep`, and `git`.

## Acceptance

- `--yolo` widens **every** tool's default to `allow`, including read-only tools
  that are already `allow`, rather than replacing the table with four entries.
- Explicit `--deny` rules still take precedence (existing contract).
- Mode widening (`readAll`, `allowEdits`) still behaves as today.
- A test asserts that under yolo no tool resolves to `ask` unless a rule says so,
  covering at least `glob`, `grep`, `search`, `ls`, `stat`, `which`, `fetch`,
  `web_search`.
- The headless refusal hint is not emitted when `--yolo` is already in effect.
