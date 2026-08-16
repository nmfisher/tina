#!/usr/bin/env bash
# tin-3x9v hunt, union variant. The four prior harnesses each isolated one
# hazard; this fires ALL of them simultaneously, because the two recorded
# crashes shared every condition at once (approval pending + tool output
# streaming + a keypress) and a race may need the full overlap:
#
#   - the FULL tin-r2vd reply bundle re-injected mid-run (measured: 4837 key
#     events in ~200 ms — far past the pump's 256-slot queue cap, so the pump
#     thread blocks in pump_push while the isolate renders) at 10 s / 22 s /
#   34 s / 46 s;
#   - a resize storm cycling 120x40 → 80x24 → 60x15 → 200x50 every 0.4 s
#     (plane geometry churn through the tin-m2vq reconcile path);
#   - a 'y' key every 0.4 s (approval resolution attempts mid-stream).
#
# Any run that dies natively prints the pane. Compare crash_replyburst.sh
# (burst, no resize), crash_resize.sh (resize, no burst), crash_oscstress.sh
# (slow palette probes).
#
# Usage: tool/crash_union.sh [runs] [outdir]
# Needs: the stub server on 127.0.0.1:8907 with scenario crash_stream2, and a
# stub HOME at /tmp/stubhome (see crash_replyburst.sh for why HOME is
# overridden rather than editing the user's config).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
runs="${1:-3}"
outdir="${2:-/tmp/crash_union}"
mkdir -p "$outdir"
sess="crashun"
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

  # Wait for the app's query burst before injecting the init replies, so the
  # injection lands inside notcurses' reply window and the app comes up.
  for _ in $(seq 1 120); do
    grep -q "1049h" "$outdir/$run_id.raw" 2>/dev/null && break
    sleep 1
  done
  TMUX_INJECT_SLEEP=0 "$here/tmux_inject_replies.sh" "$sess" >/dev/null 2>&1 || true
  sleep 8
  tmux send-keys -t "$sess" -l "Summarize the repository layout."
  sleep 1
  tmux send-keys -t "$sess" Enter

  # All three stressors at once, ~50 s. Bursts land on the marked iterations.
  geos=("120x40" "80x24" "60x15" "200x50" "80x24" "120x40")
  for i in $(seq 1 125); do
    g="${geos[$((i % ${#geos[@]}))]}"
    tmux resize-window -t "$sess" -x "${g%x*}" -y "${g#*x}" 2>/dev/null \
      || tmux resize-pane -t "$sess" -x "${g%x*}" -y "${g#*x}" 2>/dev/null || true
    tmux send-keys -t "$sess" y 2>/dev/null || true
    case "$i" in
      25|55|85|115) TMUX_INJECT_SLEEP=0 "$here/tmux_inject_replies.sh" "$sess" >/dev/null 2>&1 || true ;;
    esac
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
