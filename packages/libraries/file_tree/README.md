# file_tree

Shared filesystem collection without agents, classifiers, permissions policy,
or terminal dependencies.

- `GitFileEnumerator` returns a bounded Git inventory, including tracked and
  non-ignored untracked paths. The caller supplies process creation through
  `StartGit`; cancellation, deadlines and incomplete listings remain explicit.
- `scan` builds `Entry` objects keyed by relative path in a `Snapshot`. The
  caller supplies a complete file listing and optional bounded content reader.
  Ignore rules and permissions remain with the caller. Invalid paths, inventory
  failures and limit violations fail the scan.
- `diff` reports added, removed and changed paths, including their ancestors.
  Names and content hashes are separate. A names-only scan never reads contents;
  a content hash uses bytes, not modification times. Empty directories are not
  inferred from a file inventory; an empty inventory still has a root entry.
- `readFile` reads a regular file within a byte limit, checks for symlinks before
  and after, and rejects detected changes. An optional host validator runs at
  both points. This is not an OS sandbox; the caller retains that responsibility.

```dart
final snapshot = await scan(
  list: () async {
    final listing = await git.enumerate(root);
    if (listing.status != GitListingStatus.completed || listing.gaps.isNotEmpty) {
      throw FileEnumerationException(listing);
    }
    return listing.paths;
  },
  include: includePath,
);
```

Filter tracked files deleted from the working tree and apply the application's
symlink policy when supplying a live inventory. The engine's existing Git
enumerator delegates to this package while preserving its tracked process runner.
Tina's classification adapter uses its sandbox and permission policy when reading.
