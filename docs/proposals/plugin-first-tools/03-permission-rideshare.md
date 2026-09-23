# PT2 — Permission defaults ride with tools

Status: proposed.
Prerequisites: PT1.
Index: [README.md](README.md).

## Problem

After PT1 the tool set is pluggable but the interactive-main allow-table is
not: `buildAgent`'s `mainPolicy` hardcodes
`'delegate': allow, 'send': allow, 'receive': allow, 'close': allow,
'render_image': allow, 'stop_workflow': allow, 'repo_structure': allow,
'list_regions': allow, 'read_summary': allow, 'query_region': allow,
'allocate_region': allow, 'ask_user': allow` — twelve names whose rationale
lives in a comment block far from the tools. A plugin that contributes a
tool today cannot say "this one is a cheap read, don't prompt for it," so a
custom tool always costs the user a modal. That defeats the extension story
PT1 built.

## Design

Tools that deserve a non-default decision declare it where they are built:

```dart
abstract class Tool {
  // ... existing schema, execute ...
  /// Suggested decision when this tool is mounted on an interactive main.
  /// Null (the default) = inherit the policy's default (`ask`), which is
  /// what heavyweight tools want.
  PermissionDecision? get interactiveDefault => null;
}
```

`buildAgent`'s widening becomes a merge, not a table:

```dart
final mainPolicy = PermissionPolicy(
  defaults: {
    ...policy.defaults,
    for (final t in agentTools.names)
      if (t.interactiveDefault case final d?) t.schema.name: d,
  },
  ...
);
```

Properties that must hold (each is a golden):

- **Same twelve defaults.** The built-in tools declare exactly the decisions
  the hardcoded table names today; the merge produces the identical table.
- **User config still wins.** Static rules and the config policy base are
  applied after the merge, exactly as today — a tool's suggestion cannot
  override an explicit `--deny` or `[permissions]` rule.
- **`--yolo` unchanged.** `allowAllByDefault` rides along as today; a
  suggestion is only consulted for tools the table does not name, and under
  yolo everything resolves allow anyway.
- **Headless keeps the un-widened policy.** The merge happens only on the
  `withSubAgents` branch, as the widening does today.
- **The orchestrator guard is untouched.** Suggestions never widen what a
  guard blocks; enforcement (the policy engine, the asker) does not change.

The rationale comments move with the tools (`stop_workflow`: time-sensitive
cancel; `query_region`: cheap one-shot read; `launch_workflow`: *stays* on
`ask` — a heavyweight autonomous run deserves the modal — which is simply
`interactiveDefault => null`).

## Security note (deliberate boundary)

`interactiveDefault` is a *suggestion*, merged under user config, and the
policy engine applies it. It cannot grant outside-sandbox execution, widen a
guard, or affect non-interactive builds. Still: a third-party plugin can now
reduce prompting for its own tool by default. That is the same trust level
as the plugin's code executing at all — plugins are trusted Dart, compiled
in — but the release notes and `docs/features/plugins.md` (if present) must
say so plainly.

## Migration

1. Add the getter (default null) to `Tool`; no behavior change.
2. Move the twelve decisions onto the built-in tools; delete the hardcoded
   table; install the merge. Goldens prove the table is identical.
3. Docs: one paragraph in the plugins feature doc on the suggestion and its
   trust caveat.

## Validation

- Table-identity golden: resolve every tool name under
  {default, yolo, custom `[permissions]` rules} × {interactive, headless}
  and diff against pre-refactor output — zero differences.
- A test tool with `interactiveDefault: allow` is promptless on the
  interactive main and still `ask` headless.
- `--deny 'myplugin:*'` beats the suggestion.
