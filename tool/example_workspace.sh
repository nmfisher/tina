#!/usr/bin/env bash
# Create or reset the deliberate dirty-git state of examples/workspace.
#
# The workspace ships pristine inside the tina repo. `dirty` applies a
# deterministic set of changes (one staged edit, one unstaged edit, one
# untracked file) so git-aware features in tina (file completion, dirty
# markers, diff previews) have something to chew on. `reset` restores
# the pristine state via git.
#
# Usage (from the repo root):
#   tool/example_workspace.sh dirty
#   tool/example_workspace.sh reset
#   tool/example_workspace.sh status
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
ws="$repo_root/examples/workspace"

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
    git -C "$repo_root" checkout -- "$ws" 2>/dev/null || true
    git -C "$repo_root" reset -q HEAD -- "$ws" 2>/dev/null || true
    git -C "$repo_root" clean -fdq -- "$ws"
    # macOS sed writes sidecars; clean anything left behind.
    find "$ws" -name '*.bak' -delete
    echo "examples/workspace restored to pristine state."
    ;;
  status)
    git -C "$repo_root" status --short -- "$ws"
    ;;
  *)
    echo "usage: $0 {dirty|reset|status}" >&2
    exit 64
    ;;
esac
