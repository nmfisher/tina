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

# Poll for the compile to finish (see crash_hunt.sh — injecting into the
# compiling shell echoes the replies and the app then hangs at init), then
# inject. gdb is already loaded by the time the compile runs; the app then
# starts under gdb's control.
build_seen=0
for i in $(seq 1 60); do
  sleep 3
  if tmux capture-pane -p -t "$sess" 2>/dev/null | grep -q "Running build hooks"; then
    build_seen=1
  elif [ "$build_seen" = 1 ]; then
    break
  fi
done
sleep 3
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
