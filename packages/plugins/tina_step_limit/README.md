# tina/step-limit

Optional foreground model-round policy. Disabled by default; without this
plugin the engine has no step ceiling. Enable it in Settings → Plugins.

The plugin's Settings section offers a global numeric allowance. Changes take
effect on the next input turn. `0` means unlimited; negative or noninteger values
are rejected. Enablement can be scoped to a workspace; the numeric value is
global in the injected config file:

```toml
[plugin_config."tina/step-limit"]
max_steps_per_turn = 50
```

A step is one foreground model response and all tools it requests. Three tools
in one response count as one step. The Nth round's tools finish and are recorded;
the plugin stops before round N+1. A final answer on round N succeeds normally.
Compaction, classification and provider retries do not count as extra rounds.

Each session/panel receives its own instance and counter. Resumed sessions start
a fresh allowance on their next input. Subagents use their separately assembled
plugin set: this policy is not implicitly inherited by children. Headless callers
can supply their own StepLimitPlugin instance to each child when desired.

The policy uses the engine's generic stop request rather than throwing an error
or pretending the provider failed. It does not erase history; send another input
to continue after reaching a configured limit.
