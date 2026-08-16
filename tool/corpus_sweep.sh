#!/usr/bin/env bash
# Run a corpus pass (T1-T13, T15) at one geometry against the real provider,
# capturing each task's final pane under /tmp/corpus_<geom>/ and resetting the
# fixture between tasks. One task per fresh tmux session (tina_sweep_task.sh
# kills the server itself). Usage:
#   tool/corpus_sweep.sh 80x24 [t1 t2 ...]      # default: t1..t13 t15
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

# Single-instance guard: a killed driver leaves its task loop orphaned and a
# second launch then fights the orphan over tmux (both kill each other's
# sessions every task). flock fails fast instead.
exec 9>/tmp/corpus_sweep.lock
flock -n 9 || { echo "another corpus pass is already running" >&2; exit 1; }

geom="${1:?usage: corpus_sweep.sh <cols>x<rows> [task...]}"
shift
if [ "$#" -gt 0 ]; then
  tasks=("$@")
else
  tasks=(t1 t2 t3 t4 t5 t6 t7 t8 t9 t10 t11 t12 t13 t15)
fi
outdir="/tmp/corpus_${geom/x/_}"
mkdir -p "$outdir"

for t in "${tasks[@]}"; do
  label="$geom-$t"
  echo "=== $label: starting ==="
  bash "$here/example_workspace.sh" reset >/dev/null
  "$here/tina_sweep_task.sh" "$label" "/tmp/sweep-prompts/$t.txt" "$geom" \
    --watch 240 > "$outdir/$t.pane" 2>&1 || true
  if grep -q "Segmentation\|Killed" "$outdir/$t.pane"; then
    echo "=== $label: APP DEAD (crash marker in pane) ==="
  else
    echo "=== $label: done (pane in $outdir/$t.pane) ==="
  fi
  bash "$here/example_workspace.sh" reset >/dev/null
done
echo "=== corpus pass complete: $outdir ==="
