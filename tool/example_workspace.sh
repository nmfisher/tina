#!/usr/bin/env bash
# Create, reset, snapshot, or restore the example workspace state.
#
# The workspace ships pristine inside the tina repo. `dirty` applies a
# deterministic set of changes (one staged edit, one unstaged edit, one
# untracked file) so git-aware features in tina (file completion, dirty
# markers, diff previews) have something to chew on. `reset` restores
# the pristine state via git.
#
# `snapshot` / `restore` capture ARBITRARY states — including untracked
# files, half-finished agent edits, and the git staged/unstaged split
# (staged diff saved as a sidecar patch) that git-tracked reset can't
# see — as tarballs under build/workspace-snapshots/ (gitignored). Used
# to replay a buggy mid-task state when verifying a fix; see
# tool/sweep_tasks.md.
#
# Usage (from the repo root):
#   tool/example_workspace.sh dirty
#   tool/example_workspace.sh reset
#   tool/example_workspace.sh status
#   tool/example_workspace.sh snapshot <name>
#   tool/example_workspace.sh restore <name>
#   tool/example_workspace.sh snapshots
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
ws="$repo_root/examples/workspace"
snap_dir="$repo_root/build/workspace-snapshots"

case "${1:-}" in
  dirty)
    # Unstaged edit: append a TODO to the core README.
    printf '\n## TODO\n\n- document the FakeClock seeding convention\n' \
      >> "$ws/packages/core/README.md"
    # Staged edit: bump the core version (staged via git add below).
    sed -i.bak 's/^version: 0\.2\.0$/version: 0.2.1/' \
      "$ws/packages/core/pubspec.yaml" && rm -f "$ws/packages/core/pubspec.yaml.bak"
    git -C "$repo_root" add "$ws/packages/core/pubspec.yaml"
    # Untracked file: scratch notes.
    printf 'scratch notes — untracked on purpose\n' > "$ws/NOTES.md"
    echo "examples/workspace is now dirty:"
    git -C "$repo_root" status --short -- "$ws"
    ;;
  reset)
    # git restore only works for tracked files. If the workspace was never
    # committed, `git clean` below would DELETE it — refuse first.
    if ! git -C "$repo_root" ls-files --error-unmatch \
        "$ws/README.md" >/dev/null 2>&1; then
      echo "refusing to reset: $ws is not committed to git yet." >&2
      echo "commit the workspace first, then run reset." >&2
      exit 1
    fi
    # Unstage first, THEN checkout — the other order restores the working
    # tree from a still-dirty index and the edit survives as unstaged.
    git -C "$repo_root" reset -q HEAD -- "$ws" 2>/dev/null || true
    git -C "$repo_root" checkout -- "$ws" 2>/dev/null || true
    git -C "$repo_root" clean -fdq -- "$ws"
    # macOS sed writes sidecars; clean anything left behind.
    find "$ws" -name '*.bak' -delete
    echo "examples/workspace restored to pristine state."
    ;;
  status)
    git -C "$repo_root" status --short -- "$ws"
    ;;
  snapshot)
    name="${2:?usage: $0 snapshot <name>}"
    mkdir -p "$snap_dir"
    # --exclude '._*': macOS sidecar files the T7 volume recreates.
    tar --exclude '._*' -czf "$snap_dir/$name.tar.gz" \
      -C "$repo_root/examples" workspace
    # The git index lives outside the tarball — capture any staged edits
    # as a patch so restore can reproduce the staged/unstaged split.
    git -C "$repo_root" diff --cached --binary -- "$ws" \
      > "$snap_dir/$name.staged.patch"
    echo "snapshot saved: build/workspace-snapshots/$name.tar.gz"
    ;;
  restore)
    name="${2:?usage: $0 restore <name>}"
    archive="$snap_dir/$name.tar.gz"
    if [[ ! -f "$archive" ]]; then
      echo "no such snapshot: $name (see '$0 snapshots')" >&2
      exit 1
    fi
    # Never delete the old tree in place. On this exFAT volume a dirent
    # can go inconsistent (readdir lists the file, lookup gets ENOENT),
    # leaving a directory rm -rf cannot empty. Renaming the tree aside
    # dodges the phantom entirely: extract fresh, swap, then best-effort
    # clean the aside.
    tmp="$snap_dir/.restore.$$"
    aside="$snap_dir/.aside.$$"
    rm -rf "$tmp"
    mkdir -p "$tmp"
    tar -xzf "$archive" -C "$tmp"
    if [[ -e "$ws" ]]; then mv "$ws" "$aside"; fi
    mv "$tmp/workspace" "$ws"
    rmdir "$tmp"
    if ! rm -rf "$aside" 2>/dev/null; then
      echo "note: old tree parked at $aside (corrupt dirent on this" >&2
      echo "volume; undeletable until remount/fsck). Harmless and ignored." >&2
    fi
    # Reproduce the staged/unstaged git split: clear the index for the
    # workspace, then re-apply whatever was staged when snapshotted.
    git -C "$repo_root" reset -q HEAD -- "$ws" 2>/dev/null || true
    patch="$snap_dir/$name.staged.patch"
    if [[ -s "$patch" ]]; then
      git -C "$repo_root" apply --cached "$patch"
    fi
    echo "workspace restored from snapshot: $name"
    ;;
  snapshots)
    if [[ -d "$snap_dir" ]]; then
      (cd "$snap_dir" && ls -1 ./*.tar.gz 2>/dev/null | sed 's/\.tar\.gz$//') || true
    fi
    ;;
  *)
    echo "usage: $0 {dirty|reset|status|snapshot <name>|restore <name>|snapshots}" >&2
    exit 64
    ;;
esac
