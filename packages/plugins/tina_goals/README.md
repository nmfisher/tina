# tina_goals

Owns goal state, prompt instructions, post-turn judgments and `/goal`. State is
persisted as namespaced snapshots in the session log.

`runToGoal` provides headless orchestration: set the goal, run a turn, wait for
the post-turn judge, and continue only when its verdict is `inProgress`. An
optional positive `maxTurns` belongs to this plugin; the engine has no implicit
limit. Achieved goals succeed. Failed/uncertain judgments, failed turns,
shutdown, changed goals and exhausted explicit bounds return false.
