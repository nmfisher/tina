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
# kill-server can race a dying server and leave the session name taken;
# retry the create once before giving up (orphaned sessions from killed runs).
tmux kill-session -t "${sess}" >/dev/null 2>&1 || true
# Reset the warm environment record so the first-load ceremony streams in the
# background (the crash's streaming+approval interleave).
rm -f /workspace/examples/workspace/.tina/environment/tracking.json
rm -f /workspace/examples/workspace/ENVIRONMENT.md
if ! tmux new-session -d -x 120 -y 40 -s "$sess" 2>/dev/null; then
  sleep 1
  tmux kill-session -t "$sess" >/dev/null 2>&1 || true
  tmux new-session -d -x 120 -y 40 -s "$sess"
fi
tmux send-keys -t "$sess" "cd /workspace/examples/workspace" Enter
sleep 1
tmux pipe-pane -t "$sess" -o "cat >> $outdir/$run_id.raw"
tmux send-keys -t "$sess" "ulimit -c unlimited; gdb -q -batch -ex run -ex 'bt 60' --args dart run /workspace/bin/tina.dart" Enter

# Inject the replies the moment the app's notcurses init query burst appears
# in the run's raw log — inside notcurses' reply window (see crash_hunt.sh).
for i in $(seq 1 120); do
  if grep -q "1049h" "$outdir/$run_id.raw" 2>/dev/null; then
    break
  fi
  sleep 1
done
TMUX_INJECT_SLEEP=0 "$here/tmux_inject_replies.sh" "$sess" >/dev/null 2>&1 || true
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
