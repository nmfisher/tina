# CLI development tools

Run from the repository root unless a command specifies a working directory.

- `dart apps/tina_cli/tool/generate_version.dart` embeds the version from this
  application's pubspec. It works from any directory and uses only the SDK.
- `dart run apps/tina_cli/tool/stub_server.dart --scenario normal` serves canned
  model responses; see [scenario documentation](stub/README.md).
- `dart apps/tina_cli/tool/pipes_probe.dart --workspace /tmp/pipes-demo` is the
  stage-1 scripted client: it spawns the headless engine over stdio
  (`--pipes`), drives a real provider turn with a tool call and a file edit,
  cancels mid-turn over the pipe, and proves a second turn still works.
  Credentials stay in the environment (never a file).
  Deterministic, offline coverage of the same protocol lives in
  `test/pipes_test.dart` (local stub provider, no network).
- `python3 apps/tina_cli/tool/startup_bench.py --builds jit --runs 1` checks
  startup measurements against a local model stub, with isolated home and data.

For AOT startup measurements, first build inside `apps/tina_cli`:

```sh
dart build cli -t tool/perf/startup_stages.dart -o build/perf/stages
```

Then run the startup driver with `--builds aot` (or omit `--builds` for both).
SQLite transaction benchmarks and crash recovery tooling are owned by
`packages/tina_sqlite/tool`.
