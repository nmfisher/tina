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
# kill-server can race a dying server and leave the session name taken;
# retry the create once before giving up (orphaned sessions from killed runs).
tmux kill-session -t "${sess}" >/dev/null 2>&1 || true
rm -f /workspace/examples/workspace/.tina/environment/tracking.json
rm -f /workspace/examples/workspace/ENVIRONMENT.md
curl -s -X POST http://127.0.0.1:8787/__reset >/dev/null
if ! tmux new-session -d -x 120 -y 40 -s "$sess" 2>/dev/null; then
  sleep 1
  tmux kill-session -t "$sess" >/dev/null 2>&1 || true
  tmux new-session -d -x 120 -y 40 -s "$sess"
fi
tmux send-keys -t "$sess" "cd /workspace/examples/workspace" Enter
sleep 1
rm -f "$outdir/$run_id.raw"
tmux pipe-pane -t "$sess" -o "cat >> $outdir/$run_id.raw"
tmux send-keys -t "$sess" "HOME=/tmp/sweep-home dart run /workspace/bin/tina.dart" Enter
# Inject the replies the moment the app's notcurses init query burst appears
# in the run's raw log (see crash_hunt.sh) — inside notcurses' reply window.
for i in $(seq 1 120); do
  if grep -q "1049h" "$outdir/$run_id.raw" 2>/dev/null; then
    break
  fi
  sleep 1
done
TMUX_INJECT_SLEEP=0 "$here/tmux_inject_replies.sh" "$sess" >/dev/null
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
