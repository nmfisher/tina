# tina_workflows

The optional workflow plugin extracted from `tina_host`. It retains Attractor
for DOT parsing, graph validation, branching and workflow execution. Each agent
node runs a turn on the supplied session loop; human gates use the supplied
terminal. The catalog, default graph, commands, persistence and tests are kept.

The new app does not depend on or mount this package. Dependency direction is
`tina_workflows → tina_engine_2` and `tina_workflows → attractor`; the host and TUI
have no reverse dependency. The architecture policy guards that separation.
Legacy application workflow and classification integrations are unchanged.

```sh
dart pub get
dart analyze
dart test
```
