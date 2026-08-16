#!/usr/bin/env bash
# Run one sweep task end-to-end: fresh tmux session at a geometry, tina
# launch, reply injection, task prompt typed slowly (avoids the paste
# detector eating the trailing Enter), approve-loop over tool-call prompts,
# final capture. Prints the pane at the end and on approval changes.
#
# Usage: tool/tina_sweep_task.sh <label> <prompt-file> <cols>x<rows> [--no-approve] [--watch <s>]
#   --no-approve: do not auto-approve; leave approvals pending (for permission-gate tasks)
#   --watch <s>:   total watch time in seconds after the prompt is submitted (default 120)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

label="$1"; promptfile="$2"; geom="$3"
auto_approve=1; watch=120
shift 3
while [ $# -gt 0 ]; do
  case "$1" in
    --no-approve) auto_approve=0; shift ;;
    --watch) watch="$2"; shift 2 ;;
    *) shift ;;
  esac
done

tmux kill-server >/dev/null 2>&1 || true
sleep 1
# A killed driver can orphan its current session ("sweep") — kill-server then
# races a dying server and new-session fails with "duplicate session". Kill the
# session by name too, and retry the create once before giving up.
tmux kill-session -t sweep >/dev/null 2>&1 || true
rm -f /tmp/tina_raw.log
if ! tmux new-session -d -x "${geom%x*}" -y "${geom#*x}" -s sweep 2>/dev/null; then
  sleep 1
  tmux kill-session -t sweep >/dev/null 2>&1 || true
  tmux new-session -d -x "${geom%x*}" -y "${geom#*x}" -s sweep
fi
tmux send-keys -t sweep "cd /workspace/examples/workspace" Enter
sleep 1
tmux pipe-pane -t sweep -o "cat >> /tmp/tina_raw.log" >/dev/null
tmux send-keys -t sweep "dart run /workspace/bin/tina.dart" Enter
# Wait for the dart build hooks to finish before injecting the terminal
# replies — injecting while the shell is still building echoes them into the
# pane (cooked mode) and the app then hangs at notcurses init (tin-r2vd).
# With a warm cache the build is ~5-10 s.
build_seen=0
for i in $(seq 1 60); do
  sleep 3
  if tmux capture-pane -p -t sweep 2>/dev/null | grep -q "Running build hooks"; then
    build_seen=1
  elif [ "$build_seen" = 1 ]; then
    break
  fi
done
sleep 3
"$here/tmux_inject_replies.sh" sweep >/dev/null
sleep 6

# Clear any approve-keys that leaked into the editor, then type the prompt
# slowly (10-char chunks, 120ms gaps) so the paste-burst detector doesn't
# swallow the trailing Enter, then submit.
tmux send-keys -t sweep C-u
python3 - "$promptfile" <<'EOF'
import subprocess, sys, time
text = open(sys.argv[1]).read().rstrip('\n')
for i in range(0, len(text), 10):
    subprocess.run(['tmux', 'send-keys', '-t', 'sweep', '-l', text[i:i+10]], check=True)
    time.sleep(0.12)
subprocess.run(['tmux', 'send-keys', '-t', 'sweep', 'Enter'], check=True)
EOF

echo "=== $label: submitted, watching $watch s ==="
end=$((SECONDS + watch))
approvals=0
last_approval=""
stuck=0
while [ $SECONDS -lt $end ]; do
  # 'y' (allowOnce) is used: 'a' (allowAlways) intermittently fails to
  # resolve an approval in this harness (see tin-8n7c); 'y' resolves more
  # often. Steady-cadence presses can be ignored for minutes (tin-8n7c), so
  # if the same approval text persists across presses, back off and wait
  # before the next press — a press after a pause resolves it.
  if [ "$auto_approve" = 1 ]; then
    # No approval row matched (e.g. the app is still building): the grep exits
    # 1 and under pipefail would kill the watch loop — tolerate it. Match on
    # the PLAIN capture (no -e): with escapes, the colored border prefix breaks
    # the '› … │$' regex and the loop stops seeing approvals entirely.
    cur=$(tmux capture-pane -p -t sweep 2>/dev/null | grep -E '›[[:space:]]*│$' | md5sum | cut -c1-8 || true)
    if [ -n "$cur" ]; then
      if [ "$cur" = "$last_approval" ]; then
        stuck=$((stuck + 1))
      else
        stuck=0
      fi
      last_approval=$cur
      if [ "$stuck" -ge 3 ]; then
        sleep 15
        stuck=0
      fi
      tmux send-keys -t sweep y
      approvals=$((approvals + 1))
      sleep 6
    else
      sleep 6
    fi
  else
    sleep 6
  fi
done
echo "=== $label: approvals given: $approvals ==="
tmux capture-pane -p -e -t sweep
