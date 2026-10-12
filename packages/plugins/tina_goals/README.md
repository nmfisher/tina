# tina_goals

Owns goal state, prompt instructions, post-turn judgments and `/goal`. State is
persisted as namespaced snapshots in the session log.

`goalsCli` declares `--goal` and `--max-goal-turns`, validates their arguments
and supplies their headless handler through `PluginDefinition.cli`. The
application provides stdin and session operations, handles signals and closes
the session; it does not need to know the concrete goals plugin type.

`runToGoal` provides headless orchestration for `--goal`: set the goal, use it
as the initial instruction, run a turn, wait for
the post-turn judge, and continue only when its verdict is `inProgress`. An
optional positive `maxTurns` belongs to this plugin; the engine has no implicit
limit. Achieved goals succeed. Failed/uncertain judgments, failed turns,
shutdown, changed goals and exhausted explicit bounds return false.
