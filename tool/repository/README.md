# Repository checks

This package owns architecture enforcement and CI package selection. It has no
application, console, SQLite or native-build dependencies. Checks read each
owned package's source and package configuration without loading its code.

From the repository root:

```sh
(cd tool/repository && dart pub get)
dart run tool/repository/bin/resolve_owned.dart
dart run tool/repository/bin/check_architecture.dart
(cd tool/repository && dart test)
dart analyze
```

`resolve_owned.dart` runs `pub get` for the packages in `policy.json`, four at a
time. `check_architecture.dart --report` emits dependency violations as JSON.
`select_packages.dart` is the CI entry point; `BASE_SHA` selects the comparison
revision, or `--full` selects every owned package.

The repository root has no `pubspec.yaml`. CLI version generation, stub-model
fixtures and startup measurements belong to `apps/tina_cli/tool`. Native
keyboard/rendering probes belong to `packages/tina_console/tool`; SQLite
benchmarks and recovery checks belong to `packages/tina_sqlite/tool`.
