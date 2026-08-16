#!/usr/bin/env bash
# tin-8n7c vanish hunt: approvals + 'y' at a steady cadence. Watches whether
# the approvals resolve (answer char visible) or the keys vanish/leak.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
sess="vanish"
outdir="${1:-/tmp/vanish_hunt}"
mkdir -p "$outdir"
run_id="$(date +%H%M%S)"

tmux kill-server >/dev/null 2>&1 || true
sleep 1
rm -f /workspace/examples/workspace/.tina/environment/tracking.json
rm -f /workspace/examples/workspace/ENVIRONMENT.md
curl -s -X POST http://127.0.0.1:8787/__reset >/dev/null
tmux new-session -d -x 120 -y 40 -s "$sess"
tmux send-keys -t "$sess" "cd /workspace/examples/workspace" Enter
sleep 1
tmux send-keys -t "$sess" "HOME=/tmp/sweep-home dart run /workspace/bin/tina.dart" Enter
for i in $(seq 1 40); do
  sleep 3
  if tmux capture-pane -p -t "$sess" 2>/dev/null | grep -q "Running build hooks"; then
    break
  fi
done
sleep 60
"$here/tmux_inject_replies.sh" "$sess" >/dev/null
sleep 8
tmux send-keys -t "$sess" -l "Run the command."
sleep 1
tmux send-keys -t "$sess" Enter

# Steady-cadence 'y' presses, 3 s apart — the vanish cadence from the ticket.
for i in $(seq 1 12); do
  tmux send-keys -t "$sess" y
  sleep 3
done
sleep 2
tmux capture-pane -p -e -t "$sess" > "$outdir/$run_id.pane"
echo "RUN $run_id: captured"
