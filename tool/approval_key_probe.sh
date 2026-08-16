#!/usr/bin/env bash
# Deterministic probe: with an approval row pending, does a SINGLE 'y' resolve
# it, or land in the editor?
#
# Motivation: corpus panes at 200x50 (and 80x24 before) end with an approval
# row visible AND 'y's accumulated in the editor — but the corpus driver counts
# y *presses* as "approvals given", so it cannot distinguish a resolved
# approval from an ignored one. This probe sends exactly one key and diffs the
# pane around it.
#
# Usage: tool/approval_key_probe.sh [key] [geometry]
#   key defaults to y; geometry defaults to 120x40.
# Needs the stub server on 127.0.0.1:8907 (scenario crash_stream2) and
# /tmp/stubhome. Prints BEFORE / AFTER captures and a verdict.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
key="${1:-y}"
geom="${2:-120x40}"
cols="${geom%x*}"; rows="${geom#*x}"
sess="appprobe"
out="/tmp/approval_probe"
mkdir -p "$out"

curl -s -X POST http://127.0.0.1:8907/__reset >/dev/null 2>&1 || true
tmux kill-server >/dev/null 2>&1 || true
sleep 1
tmux new-session -d -x "$cols" -y "$rows" -s "$sess"
tmux send-keys -t "$sess" "cd /workspace/examples/workspace" Enter
sleep 1
tmux pipe-pane -t "$sess" -o "cat >> $out/run.raw"
tmux send-keys -t "$sess" "HOME=/tmp/stubhome dart run /workspace/bin/tina.dart" Enter

# Come up: wait for the notcurses query burst, then inject the init replies.
for _ in $(seq 1 120); do
  grep -q "1049h" "$out/run.raw" 2>/dev/null && break
  sleep 1
done
TMUX_INJECT_SLEEP=0 "$here/tmux_inject_replies.sh" "$sess" >/dev/null 2>&1 || true
sleep 8
tmux send-keys -t "$sess" -l "Summarize the repository layout."
sleep 1
tmux send-keys -t "$sess" Enter

# Wait for an approval row (the stub's bash call), then act once.
approval_seen=""
for i in $(seq 1 40); do
  if tmux capture-pane -p -t "$sess" 2>/dev/null | grep -Eq '›[[:space:]]*│$'; then
    approval_seen="yes"
    break
  fi
  sleep 1
done
if [ -z "$approval_seen" ]; then
  echo "VERDICT: inconclusive — no approval row appeared in 40 s"
  tmux capture-pane -p -t "$sess"
  exit 0
fi

tmux capture-pane -p -t "$sess" > "$out/before.pane"
echo "=== BEFORE (approval row + editor) ==="
sed 's/\x1b\[[0-9;]*m//g' "$out/before.pane" | grep -E 'approve\?|^>' | tail -3

sleep 2
tmux send-keys -t "$sess" "$key"
sleep 4
tmux capture-pane -p -t "$sess" > "$out/after.pane"
echo "=== AFTER (same rows) ==="
sed 's/\x1b\[[0-9;]*m//g' "$out/after.pane" | grep -E 'approve\?|^>' | tail -3

# Verdict. An answered approval does NOT disappear: askPermission echoes the
# answer char onto the row (`chat.write('$ch\n')`, tui_conversation_host.dart)
# and the row stays in the chat as a record — so grepping the pane for
# "approve?" reports "pending" forever. The real signal is what follows the
# row: resolved => the approved tool's output streams beneath it; pending =>
# the row is still the last content row. The echoed char is a secondary check
# (it is the answer, not text typed into an input).
strip() { sed 's/\x1b\[[0-9;]*m//g' "$1"; }
approvals_in_after=$(strip "$out/after.pane" | grep -n 'approve?' | tail -1 | cut -d: -f1)
total_rows=$(strip "$out/after.pane" | grep -c '^│[^─]')
if [ -n "$approvals_in_after" ] && [ "$approvals_in_after" -lt "$total_rows" ]; then
  echo "VERDICT: RESOLVED — content follows the approval row (row $approvals_in_after of $total_rows)"
  strip "$out/after.pane" | sed -n "$((approvals_in_after + 1)),$((approvals_in_after + 3))p"
elif strip "$out/after.pane" | grep -q "› $key"; then
  echo "VERDICT: RESOLVED — '$key' was echoed as the answer on the row"
else
  echo "VERDICT: STILL PENDING — nothing followed the approval row"
fi
tmux kill-server >/dev/null 2>&1 || true
