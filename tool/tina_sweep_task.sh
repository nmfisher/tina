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
rm -f /tmp/tina_raw.log
tmux pipe-pane -t sweep -o "cat >> /tmp/tina_raw.log" >/dev/null
tmux send-keys -t sweep "dart run /workspace/bin/tina.dart" Enter
# Inject the terminal replies the moment the app's notcurses init query burst
# appears in the raw log (the alt-screen enter + CPR are the first queries).
# This lands inside notcurses' reply window (~2 s):
#  - earlier (during the compile) the replies echo into the cooked shell and
#    are lost — the app then blocks at init (tin-r2vd);
#  - later, notcurses' reply window has closed and the replies leak into the
#    editor as input — the OSC4 palette garbage lands inside the typed prompt.
for i in $(seq 1 90); do
  if grep -q "1049h" /tmp/tina_raw.log 2>/dev/null; then
    break
  fi
  sleep 1
done
TMUX_INJECT_SLEEP=0 "$here/tmux_inject_replies.sh" sweep >/dev/null
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
# Pause before the Enter so it clears the paste-burst join window (30 ms).
# A folded Enter turns the submission into a PasteInput whose \n never
# submits the line — and an approval's pendingLine wait then stalls on it.
time.sleep(0.15)
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
