#!/usr/bin/env bash
# tin-3x9v hunt, resize variant. Third distinct native hazard: plane geometry
# churn. NotcursesBackendSurface.resize() re-parents a panel plane with a
# zero-size keep region while the ceremony/panels hold relative coordinates;
# tin-4k8w fixed the shrink-reconcile render bug in this area, and both
# recorded crashes sat at an approval with panels + streaming in flight. This
# harness resizes the pane in a grow/shrink storm (including the nasty 60x15)
# while a bash tool call streams and keys are pressed.
#
# Usage: tool/crash_resize.sh [runs] [outdir]
# Needs: the stub server on 127.0.0.1:8907 with scenario crash_stream2 and a
# stub HOME at /tmp/stubhome (see crash_replyburst.sh).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
runs="${1:-2}"
outdir="${2:-/tmp/crash_resize}"
mkdir -p "$outdir"
sess="crashrsz"
stubhome="${STUB_HOME:-/tmp/stubhome}"

for run in $(seq 1 "$runs"); do
  run_id="$(date +%H%M%S)_$run"
  curl -s -X POST "http://127.0.0.1:8907/__reset" >/dev/null 2>&1 || true
  tmux kill-server >/dev/null 2>&1 || true
  sleep 1
  tmux kill-session -t "$sess" >/dev/null 2>&1 || true
  rm -f /workspace/examples/workspace/.tina/environment/tracking.json
  rm -f /workspace/examples/workspace/ENVIRONMENT.md
  if ! tmux new-session -d -x 120 -y 40 -s "$sess" 2>/dev/null; then
    sleep 1; tmux new-session -d -x 120 -y 40 -s "$sess"
  fi
  tmux send-keys -t "$sess" "cd /workspace/examples/workspace" Enter
  sleep 1
  tmux pipe-pane -t "$sess" -o "cat >> $outdir/$run_id.raw"
  tmux send-keys -t "$sess" "HOME=$stubhome dart run /workspace/bin/tina.dart" Enter

  for _ in $(seq 1 120); do
    grep -q "1049h" "$outdir/$run_id.raw" 2>/dev/null && break
    sleep 1
  done
  TMUX_INJECT_SLEEP=0 "$here/tmux_inject_replies.sh" "$sess" >/dev/null 2>&1 || true
  sleep 8
  tmux send-keys -t "$sess" -l "Summarize the repository layout."
  sleep 1
  tmux send-keys -t "$sess" Enter

  # Resize storm for ~45 s: cycle through geometries every 0.4 s (a shrink
  # below the layout minimum is the interesting case), keys throughout.
  geos=("120x40" "80x24" "60x15" "200x50" "80x24" "120x40")
  for i in $(seq 1 110); do
    g="${geos[$((i % ${#geos[@]}))]}"
    tmux resize-window -t "$sess" -x "${g%x*}" -y "${g#*x}" 2>/dev/null \
      || tmux resize-pane -t "$sess" -x "${g%x*}" -y "${g#*x}" 2>/dev/null || true
    if [ $((i % 2)) -eq 0 ]; then
      tmux send-keys -t "$sess" y 2>/dev/null || true
    fi
    sleep 0.4
    tmux has-session -t "$sess" 2>/dev/null || break
  done
  tmux capture-pane -p -t "$sess" > "$outdir/$run_id.pane" 2>/dev/null || true
  if grep -q "Segmentation\|Killed\|SIGSEGV" "$outdir/$run_id.pane" 2>/dev/null; then
    echo "RUN $run_id: APP DEAD"
    grep -n "Segmentation\|SIGSEGV\|Killed" "$outdir/$run_id.pane" | head -3
  else
    echo "RUN $run_id: alive"
  fi
  tmux kill-server >/dev/null 2>&1 || true
done
