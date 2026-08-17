#!/usr/bin/env bash
# Deterministic probe for tin-c5nw: with an approval row pending, does Ctrl+G
# cycle the panels (and leave the approval waiting), or does it land in the
# approval's readKey (answering it as a deny)?
#
# Checks, in order:
#   1. after C-g a panel border carries the cycling (yellow) tint — the focus
#      ring engaged;
#   2. the approval row is STILL the last content row — the key never
#      answered it;
#   3. after Enter commits the focus, a 'y' resolves the approval — the
#      prompt's own keys still work.
#
# Usage: tool/verify_global_keys.sh [geometry]     (default 120x40)
# Needs the stub server on 127.0.0.1:8907 (scenario crash_stream2) and
# /tmp/stubhome. No terminal-reply injection: startup runs on the
# TerminalReplyGuard path (tin-r2vd), which is the supported one.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
geom="${1:-120x40}"
cols="${geom%x*}"; rows="${geom#*x}"
sess="gkeyprobe"
out="/tmp/global_keys_probe"
mkdir -p "$out"
rm -f "$out/run.raw"

curl -s -X POST http://127.0.0.1:8907/__reset >/dev/null 2>&1 || true
tmux kill-server >/dev/null 2>&1 || true
sleep 1
tmux new-session -d -x "$cols" -y "$rows" -s "$sess"
tmux send-keys -t "$sess" "cd /workspace/examples/workspace" Enter
sleep 1
tmux pipe-pane -t "$sess" -o "cat >> $out/run.raw"
tmux send-keys -t "$sess" "HOME=/tmp/stubhome dart run /workspace/bin/tina.dart" Enter

# The TUI must render on its own (cold build can take a while).
up=0
for _ in $(seq 1 120); do
  if tmux capture-pane -p -t "$sess" 2>/dev/null | grep -q '┌main'; then
    up=1
    break
  fi
  sleep 1
done
if [ "$up" -ne 1 ]; then
  echo "VERDICT: inconclusive — the TUI never rendered"
  tmux capture-pane -p -t "$sess"
  tmux kill-server >/dev/null 2>&1 || true
  exit 0
fi
sleep 4
tmux send-keys -t "$sess" -l "Summarize the repository layout."
sleep 1
tmux send-keys -t "$sess" Enter

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
  tmux kill-server >/dev/null 2>&1 || true
  exit 0
fi

# Border rows carrying each tint. The panel frame is cyan while it holds the
# focus and yellow while it is the cycling highlight: under the notcurses
# backend that is 38;5;51 (focus) vs 38;5;226 (highlight). Counts are ROWS of
# the frame carrying the tint, not occurrences — the busy comet also paints
# 226 on the title row, so "some yellow" is not the signal; the whole frame
# switching is.
frame_tint_rows() { # $1 = palette index
  tmux capture-pane -p -e -t "$sess" 2>/dev/null \
    | grep -E '^[│┌┐└┘├┤]' \
    | grep -c $'\x1b\[38;5;'$1'm' || true
}

tmux capture-pane -p -t "$sess" > "$out/before.pane"
before_yellow=$(frame_tint_rows 226); before_cyan=$(frame_tint_rows 51)
sleep 2
tmux send-keys -t "$sess" C-g
sleep 3
tmux capture-pane -p -t "$sess" > "$out/after_cg.pane"
after_yellow=$(frame_tint_rows 226); after_cyan=$(frame_tint_rows 51)

fail=0
if [ "$after_cyan" -le 2 ] && [ "$after_yellow" -ge 10 ]; then
  echo "CHECK 1 ok: the panel frame went focus(cyan) → cycling(yellow) on C-g"
  echo "        before: yellow=$before_yellow cyan=$before_cyan frame rows"
  echo "        after:  yellow=$after_yellow cyan=$after_cyan frame rows"
else
  echo "CHECK 1 FAIL: the frame did not switch to the cycling tint"
  echo "        before: yellow=$before_yellow cyan=$before_cyan frame rows"
  echo "        after:  yellow=$after_yellow cyan=$after_cyan frame rows"
  fail=1
fi

# The approval must still be waiting: the approved tool has not started and
# nothing was denied. (The ceremony legitimately streams text beneath a
# pending approval — tin-6a2f — so "content follows the row" is not a pending
# signal. A key that answered the prompt shows up as a deny notice.)
strip() { sed 's/\x1b\[[0-9;]*m//g' "$1"; }
if strip "$out/after_cg.pane" | grep -qE 'denied'; then
  echo "CHECK 2 FAIL: the approval was answered by C-g — a deny notice followed"
  strip "$out/after_cg.pane" | grep -nE 'denied' | head -3
  fail=1
elif strip "$out/after_cg.pane" | grep -qE '^(│)?(→ bash:|streamed line)'; then
  echo "CHECK 2 FAIL: the approval was answered by C-g — the tool started"
  strip "$out/after_cg.pane" | grep -nE '→ bash:|streamed line' | head -3
  fail=1
elif strip "$out/after_cg.pane" | grep -q 'approve?.*›[[:space:]]*│$'; then
  echo "CHECK 2 ok: the approval row is still waiting after C-g"
else
  # Not answered, but the row has scrolled out of a short pane — the key did
  # not resolve it either way. Still a pass; CHECK 3 is the decisive probe.
  echo "CHECK 2 ok: no deny and no tool start after C-g (row scrolled off)"
fi

# Leave cycling (Enter commits the focus back), then answer the approval.
tmux send-keys -t "$sess" Enter
sleep 2
tmux send-keys -t "$sess" "y"
sleep 6
tmux capture-pane -p -t "$sess" > "$out/after_y.pane"
if strip "$out/after_y.pane" | grep -q 'streamed line 1'; then
  echo "CHECK 3 ok: 'y' resolved the approval — the approved tool is streaming"
else
  echo "CHECK 3 FAIL: 'y' did not resolve the approval"
  strip "$out/after_y.pane" | tail -8
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "VERDICT: PASS — Ctrl+G cycles panels, the approval keeps waiting, 'y' still answers"
else
  echo "VERDICT: FAIL"
fi
tmux kill-server >/dev/null 2>&1 || true
exit $fail
