#!/usr/bin/env bash
# tin-3x9v crash hunt with the REAL provider: fresh first-load (env ceremony
# streams), a corpus-style refactor task, keys hammered throughout. The pane
# reports the crash ("Segmentation fault" / shell prompt). One run per call.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
sess="crash"
outdir="${1:-/tmp/crash_hunt}"
mkdir -p "$outdir"
run_id="$(date +%H%M%S)"

tmux kill-server >/dev/null 2>&1 || true
sleep 1
rm -f /workspace/examples/workspace/.tina/environment/tracking.json
rm -f /workspace/examples/workspace/ENVIRONMENT.md
tmux new-session -d -x 120 -y 40 -s "$sess"
tmux send-keys -t "$sess" "cd /workspace/examples/workspace" Enter
sleep 1
tmux send-keys -t "$sess" "ulimit -c unlimited; dart run /workspace/bin/tina.dart" Enter

# Wait for the compile to start, then wait it out, then inject the replies.
for i in $(seq 1 40); do
  sleep 3
  if tmux capture-pane -p -t "$sess" 2>/dev/null | grep -q "Running build hooks"; then
    break
  fi
done
sleep 60
"$here/tmux_inject_replies.sh" "$sess" >/dev/null 2>&1 || true
sleep 10

tmux send-keys -t "$sess" -l "Refactor the store package to expose a count query method and wire it into the cli as a count subcommand."
sleep 1
tmux send-keys -t "$sess" Enter

# Hammer y (approve) and x (editor char) through the whole turn.
for i in $(seq 1 240); do
  tmux send-keys -t "$sess" y
  sleep 0.6
  tmux send-keys -t "$sess" -l "x"
  sleep 0.6
done
sleep 5
tmux capture-pane -p -e -t "$sess" > "$outdir/$run_id.pane"
if grep -q "Segmentation\|Killed" "$outdir/$run_id.pane"; then
  echo "RUN $run_id: APP DEAD (see pane)"
else
  echo "RUN $run_id: alive"
fi
