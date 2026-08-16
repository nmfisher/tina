#!/usr/bin/env bash
# tin-3x9v crash hunt under gdb with the REAL provider: any SIGSEGV produces
# a native backtrace. Injection waits for the app to reach raw mode (poll the
# pane for the notcurses frame border). One run per invocation.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
sess="crash"
outdir="${1:-/tmp/crash_hunt}"
mkdir -p "$outdir"
run_id="$(date +%H%M%S)"

tmux kill-server >/dev/null 2>&1 || true
sleep 1
# Reset the warm environment record so the first-load ceremony streams in the
# background (the crash's streaming+approval interleave).
rm -f /workspace/examples/workspace/.tina/environment/tracking.json
rm -f /workspace/examples/workspace/ENVIRONMENT.md
tmux new-session -d -x 120 -y 40 -s "$sess"
tmux send-keys -t "$sess" "cd /workspace/examples/workspace" Enter
sleep 1
tmux send-keys -t "$sess" "ulimit -c unlimited; gdb -q -batch -ex run -ex 'bt 60' --args dart run /workspace/bin/tina.dart" Enter

# Poll for the compile to start ("Running build hooks" echoes in the pane),
# then wait out the compile + gdb startup before injecting the replies —
# too early and the replies land in the shell (cooked mode) and echo as
# literal text.
for i in $(seq 1 40); do
  sleep 3
  if tmux capture-pane -p -t "$sess" 2>/dev/null | grep -q "Running build hooks"; then
    break
  fi
done
sleep 75
"$here/tmux_inject_replies.sh" "$sess" >/dev/null 2>&1 || true
sleep 10

tmux send-keys -t "$sess" -l "Refactor the store package to expose a count query method and wire it into the cli as a count subcommand."
sleep 1
tmux send-keys -t "$sess" Enter

# Hammer keys through the whole turn: approvals, streaming, everything.
for i in $(seq 1 300); do
  tmux send-keys -t "$sess" y
  sleep 0.5
  tmux send-keys -t "$sess" -l "x"
  sleep 0.5
done
sleep 5
tmux capture-pane -p -e -t "$sess" > "$outdir/$run_id.pane"
if grep -q "SIGSEGV\|Segmentation" "$outdir/$run_id.pane"; then
  echo "RUN $run_id: SIGSEGV captured"
else
  echo "RUN $run_id: no crash"
fi
