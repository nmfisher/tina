# tina/step-limit

Optional foreground model-round policy. Disabled by default; without this
plugin the engine has no step ceiling. Enable it in Settings → Plugins.

The plugin declares its numeric allowance in the settings catalog. The generic
Settings panel edits it at session, workspace or global scope; no feature-specific
console adapter is needed. Changes take effect on the next input turn. `0` means
unlimited; negative or noninteger values are rejected. A global value uses:

```toml
[plugin_config."tina/step-limit"]
max_steps_per_turn = 50
```

A step is one foreground model response and all tools it requests. Three tools
in one response count as one step. The Nth round's tools finish and are recorded;
the plugin stops before round N+1. A final answer on round N succeeds normally.
Compaction, classification and provider retries do not count as extra rounds.

Each session receives its own runtime instance and counter. Views attached to
the same session share that runtime; closing a Settings panel or detaching a view
does not reset its counter or active allowance. Resumed sessions start
a fresh allowance on their next input. Subagents use their separately assembled
plugin set: this policy is not implicitly inherited by children. Headless callers
can supply their own StepLimitPlugin instance to each child when desired.
`StepLimitPlugin.configured` reads injected scoped settings at each turn, or the
global config file when scoped settings are absent. `StepLimitConfig` retains
standalone read/save access to that file format.

The policy uses the engine's generic stop request rather than throwing an error
or pretending the provider failed. It does not erase history; send another input
to continue after reaching a configured limit.
