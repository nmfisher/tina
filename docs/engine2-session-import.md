# Legacy session import

## Usage

From the repository root, preview all available legacy sessions:

```sh
dart run bin/tina.dart --import-sessions "$HOME/.tina/sessions" --dry-run
```

Convert into an explicitly chosen SQLite store, then use the printed IDs:

```sh
dart run bin/tina.dart --import-sessions "$HOME/.tina/sessions" --store /tmp/tina-import.db
dart run bin/tina.dart --store /tmp/tina-import.db --resume
dart run bin/tina.dart --store /tmp/tina-import.db --resume 'legacy:SESSION_ID:CONVERSATION_ID'
```

Choose a durable destination when ready. Without `--store`, import writes to
`<cwd>/.tina/sessions.db`; `--cwd` chooses that workspace. Import never starts
a provider or requires credentials. `--dry-run` does not open the destination
and therefore does not check destination conflicts. Exit code 65 means at
least one source failed; successful conversations remain committed. An active
conversation marker in the output identifies the old session's resume target.

Resume uses the workspace selected on launch, not the archived legacy cwd.
Stop writers to the legacy sessions before importing. To recover missing
transcripts, restore them to their recorded workspace paths or to the global
session directory as `<conversation>.jsonl`, then rerun. A changed source after
an earlier successful import requires a different destination store; imports
never replace an existing session or discard its subsequent turns.

Repeat the local acceptance check without keeping an imported database:

```sh
cd packages/plugins/tina_persistence
dart run tool/verify_local_sessions.dart "$HOME/.tina/sessions"
```

Verified locally: all 84 available conversations and 6,833 messages retained
their derived content and reasoning. Two interrupted exchanges were repaired,
16 absent transcripts were reported, and all 84 repeat imports were skipped.
The check uses a temporary database, verifies source hashes, and deletes the
temporary database afterward. Original manifests/transcripts are not modified.

## Survey and conversion contract

Legacy `JsonlSessionStore` writes a `session.json` manifest under
`~/.tina/sessions/<session>/`. Manifest versions 1 and 2 list conversations;
each transcript is `<conversation>.jsonl`. When `transcriptsLocal` is true,
the reader first checks `<cwd>/.tina/sessions/<session>/`, then the global
session directory. Earlier releases used a single `<session>.jsonl` file.
JSONL rows are messages, not engine2 log entries. They retain text, tool calls,
tool results, local reasoning and the synthetic-message marker. Compaction
rewrote the transcript; discarded pre-compaction messages cannot be recovered.

The local survey found 47 version-2 manifests, 100 listed conversations,
84 available transcripts and 6,833 messages. Sixteen transcript paths were
missing. These counts describe the inspected snapshot, not a guarantee about
another machine or later session writes. No private transcript is checked in.

The converter belongs to `tina_persistence`, with no dependency on legacy code.
Each conversation becomes an independent resumable engine2 session with a
deterministic `legacy:<session>:<conversation>` ID. Parent/active conversation,
original provider/model/cwd and the full manifest remain archival metadata.
The current app config supplies the resumed model, plugins and permissions;
legacy policies, prompt overrides and workflow roles are not reactivated.

Messages are coalesced into valid tool-result batches. Missing tool results
receive explicit unknown-execution placeholders; tools are never replayed.
An import boundary closes the historical snapshot so resume cannot replay an
unfinished legacy turn. Plans/goals are translated to current log entries;
unsupported tracker shapes remain in metadata with a warning. Legacy aggregate
token totals are archived, not invented as per-turn or per-child usage.

Writes are atomic per conversation. Source files are read only. Identical
reimports are skipped, even after the imported session has continued. Changed
sources or existing unrelated destination IDs are conflicts, never overwrites.
Missing files, malformed rows and unsupported message shapes are explicit
per-conversation failures; other conversations can still import. A dry run
performs conversion without opening or creating the destination database.

Tests cover fixture layouts and failure cases, then exercise real local files
into a temporary SQLite database and compare the derived transcript. They do
not change the user's original files or production SQLite store.
