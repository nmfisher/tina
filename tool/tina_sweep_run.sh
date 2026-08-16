#!/usr/bin/env bash
# Drive one tina TUI run under the sweep harness (docs/ui-sweep-loop.md):
# fresh detached tmux session at a geometry, launch tina, inject the
# terminal replies notcurses blocks on (tin-r2vd workaround), then run one
# task prompt and watch the pane.
#
# Usage:
#   tool/tina_sweep_run.sh start <session> <cols>x<rows> [<task prompt file>]
#   tool/tina_sweep_run.sh stop  <session>
#   tool/tina_sweep_run.sh prompt <session> <text...>     # type into the TUI
#   tool/tina_sweep_run.sh keys  <session> <key args...>  # raw send-keys
#   tool/tina_sweep_run.sh shot  <session>                # capture pane
#   tool/tina_sweep_run.sh watch <session> <seconds>      # capture after wait
#
# With a task prompt file, the prompt is typed and Enter pressed after the
# TUI is up.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

case "${1:-}" in
  start)
    sess="$2"; geom="$3"; taskfile="${4:-}"
    tmux kill-server >/dev/null 2>&1 || true
    sleep 1
    rm -f /tmp/tina_raw.log
    tmux new-session -d -x "${geom%x*}" -y "${geom#*x}" -s "$sess"
    tmux send-keys -t "$sess" "cd /workspace/examples/workspace" Enter
    sleep 1
    tmux pipe-pane -t "$sess" -o "cat >> /tmp/tina_raw.log"
    tmux send-keys -t "$sess" "ulimit -c unlimited; dart run /workspace/bin/tina.dart" Enter
    "$here/tmux_inject_replies.sh" "$sess"
    sleep 6
    if [ -n "$taskfile" ]; then
      # Type the task prompt (one line per send-keys to avoid tmux arg limits).
      tmux send-keys -t "$sess" -l "$(cat "$taskfile")" Enter
      sleep 2
    fi
    ;;
  stop)
    tmux kill-server >/dev/null 2>&1 || true
    ;;
  prompt)
    sess="$2"; shift 2
    tmux send-keys -t "$sess" -l "$*" Enter
    ;;
  keys)
    sess="$2"; shift 2
    tmux send-keys -t "$sess" "$@"
    ;;
  shot)
    sess="$2"
    tmux capture-pane -p -e -t "$sess"
    ;;
  watch)
    sess="$2"; secs="$3"
    sleep "$secs"
    tmux capture-pane -p -e -t "$sess"
    ;;
  *)
    echo "usage: $0 start|stop|prompt|keys|shot|watch ..." >&2
    exit 1
    ;;
esac
