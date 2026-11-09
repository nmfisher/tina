# Vendored SQLite amalgamation

`sqlite3.c` is the official SQLite 3.53.4 amalgamation
(https://sqlite.org/2026/sqlite-amalgamation-3530400.zip, public domain),
vendored verbatim.

The `sqlite3` package's build hook downloads a prebuilt `libsqlite3.so`
from the `simolus3/sqlite3.dart` GitHub release assets by default. That
CDN fetch failed intermittently both in CI (three jobs on one run) and on
developer machines, so this repository compiles SQLite from source
instead: every package whose `dart test` runs the hook carries a
`hooks.user_defines.sqlite3` block in its pubspec pointing here
(`source: source`, `path: .../native/sqlite3.c`). This matches the version
the release binaries ship, keeps test runs fully offline, and needs only
the C toolchain the hook runner already uses.

Update path: bump the file here, update this note, and re-run the
tina_sqlite suite.
