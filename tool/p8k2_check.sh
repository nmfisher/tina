#!/usr/bin/env bash
# tin-p8k2 deterministic repro driver: run tool/p8k2_repro.dart in a fresh
# tmux pane (the notcurses stack needs a real tty), capture the pane's raw
# byte stream via pipe-pane, then replay it through tool/p8k2_check.dart.
# Exit 0 = borders intact, exit 1 = borderless rows.
#
# Usage: tool/p8k2_check.sh [run-id]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

run="${1:-r1}"
outdir="/tmp/p8k2/$run"
mkdir -p "$outdir"
cols="${COLS:-120}"
rows="${ROWS:-40}"
sess="p8k2r"

tmux kill-server >/dev/null 2>&1 || true
sleep 1
tmux new-session -d -x "$cols" -y "$rows" -s "$sess"
tmux send-keys -t "$sess" "cd /workspace" Enter
sleep 1
tmux pipe-pane -t "$sess" -o "cat >> $outdir/raw.log"
tmux send-keys -t "$sess" \
  "/home/agent/dart-sdk/bin/dart run tool/p8k2_repro.dart --cols $cols --rows $rows; echo P8K2-EXIT=\$?" Enter

# Hold the pane open until the repro reports completion, then capture.
for _ in $(seq 1 90); do
  grep -q "P8K2-EXIT=" "$outdir/raw.log" 2>/dev/null && break
  sleep 1
done
tmux capture-pane -p -t "$sess" > "$outdir/pane.txt" || true
tmux kill-server >/dev/null 2>&1 || true

/home/agent/dart-sdk/bin/dart run tool/p8k2_check.dart "$outdir/raw.log" "$cols" "$rows"
