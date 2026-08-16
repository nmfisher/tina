#!/usr/bin/env bash
# tin-v6tq live verification. Exercises the three input regimes the reply
# filter must NOT change, in one run, against the stub provider:
#
#   1. typing — one key at a time at human cadence, must land in the editor;
#   2. a genuine bracketed paste (tmux paste-buffer -p) — must land as one
#      [Pasted text : N chars] chip, content intact;
#   3. a lone ESC — delivered (or at least never eats the keys after it);
#   4. the full reply bundle re-injected mid-run — must NOT land in the editor
#      (the fixed symptom; two ~4570-char chips before the filter).
#
# Usage: tool/verify_reply_filter.sh [session] [outdir]
# Needs: stub server on 127.0.0.1:8907 and a stub HOME at /tmp/stubhome.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
sess="${1:-v6tqverify}"
outdir="${2:-/tmp/v6tq_live}"
mkdir -p "$outdir"
stubhome="${STUB_HOME:-/tmp/stubhome}"

curl -s -X POST "http://127.0.0.1:8907/__reset" >/dev/null 2>&1 || true
tmux kill-session -t "$sess" 2>/dev/null || true
rm -f /workspace/examples/workspace/.tina/environment/tracking.json
rm -f /workspace/examples/workspace/ENVIRONMENT.md
tmux new-session -d -x 120 -y 40 -s "$sess"
tmux send-keys -t "$sess" "cd /workspace/examples/workspace" Enter
sleep 1
tmux pipe-pane -t "$sess" -o "cat >> $outdir/$sess.raw"
tmux send-keys -t "$sess" "HOME=$stubhome dart run /workspace/bin/tina.dart" Enter

# Wait for the notcurses query burst, then supply the init replies (tin-r2vd).
for _ in $(seq 1 120); do
  grep -q "1049h" "$outdir/$sess.raw" 2>/dev/null && break
  sleep 1
done
TMUX_INJECT_SLEEP=0 "$here/tmux_inject_replies.sh" "$sess" >/dev/null 2>&1 || true
sleep 8

snap() { tmux capture-pane -p -t "$sess" > "$outdir/$1.pane" 2>/dev/null; }

echo "== 1. typing (one key per 100 ms) =="
tmux send-keys -t "$sess" -l "R" ; sleep 0.1
for ch in e p l y ; do tmux send-keys -t "$sess" -l "$ch"; sleep 0.1 ; done
sleep 1
snap typed
if grep -q "Reply" "$outdir/typed.pane"; then
  echo "PASS typing lands in the editor"
else
  echo "FAIL typing did not land in the editor:"
  grep -E "^│>|^>" "$outdir/typed.pane" | tail -3
fi

echo "== 2. genuine bracketed paste =="
tmux send-keys -t "$sess" C-u 2>/dev/null || true   # clear the draft line
sleep 0.3
python3 - "$sess" <<'EOF'
import subprocess, sys
sess = sys.argv[1]
# 1500 printable chars, no ESC anywhere — a genuine clipboard payload.
text = ('genuine paste payload 0123 abcdef ' * 48)[:1500]
assert '\x1b' not in text and len(text) == 1500, len(text)
subprocess.run(['tmux', 'set-buffer', '-b', 'v6tq', '--', text], check=True)
subprocess.run(['tmux', 'paste-buffer', '-p', '-b', 'v6tq', '-t', sess], check=True)
subprocess.run(['tmux', 'delete-buffer', '-b', 'v6tq'], check=True)
EOF
sleep 2
snap pasted
if grep -q "Pasted text : 1500 chars" "$outdir/pasted.pane"; then
  echo "PASS paste arrives whole as one 1500-char chip"
else
  echo "FAIL paste chip missing/wrong size:"
  grep -oE "Pasted text : [0-9]+ chars" "$outdir/pasted.pane" | head -3
  grep -E "^│>|^>" "$outdir/pasted.pane" | tail -2
fi
# And its content must be the payload, not reply bytes.
if grep -q "genuine paste payload" "$outdir/pasted.pane"; then
  echo "PASS paste content visible/correct"
elif grep -qE "rgb:|\\\$y|\?1016" "$outdir/pasted.pane"; then
  echo "FAIL paste content is reply bytes"
fi

echo "== 3. lone ESC, then typing =="
tmux send-keys -t "$sess" Escape
sleep 0.5
tmux send-keys -t "$sess" -l "o" ; sleep 0.1
tmux send-keys -t "$sess" -l "k" ; sleep 0.1
sleep 1
snap esc
if grep -q "ok" "$outdir/esc.pane"; then
  echo "PASS typing after a lone ESC still lands"
else
  echo "FAIL keys after a lone ESC were swallowed"
fi

echo "== 4. mid-run reply bundle =="
chips_before="$(grep -coE "Pasted text : [0-9]+ chars" "$outdir/esc.pane" 2>/dev/null || true)"
TMUX_INJECT_SLEEP=0 "$here/tmux_inject_replies.sh" "$sess" >/dev/null 2>&1 || true
sleep 2
snap burst
chips_after="$(grep -coE "Pasted text : [0-9]+ chars" "$outdir/burst.pane" 2>/dev/null || true)"
if grep -qE "Pasted text : (4[0-9]{3}|[0-9]{5,}) chars" "$outdir/burst.pane" ||
   grep -qE "rgb:|\\\$y|\?1016;1| XTGETTCAP|544e" "$outdir/burst.pane"; then
  echo "FAIL reply bytes reached the editor:"
  grep -oE "Pasted text : [0-9]+ chars" "$outdir/burst.pane" | head -3
  grep -nE "rgb:|\\\$y|\?1016" "$outdir/burst.pane" | head -3
elif [ "${chips_before:-0}" != "${chips_after:-0}" ]; then
  echo "FAIL chip count changed across the burst ($chips_before -> $chips_after)"
else
  echo "PASS reply bundle discarded (chips $chips_before -> $chips_after, no residue)"
fi
tmux send-keys -t "$sess" -l "z" ; sleep 0.1
tmux send-keys -t "$sess" -l "z" ; sleep 0.1
sleep 1
snap after
if grep -q "zz" "$outdir/after.pane"; then
  echo "PASS typing after the burst still lands"
else
  echo "FAIL typing after the burst was swallowed (filter stuck open?)"
fi

if grep -q "Segmentation\|SIGSEGV\|Killed" "$outdir/after.pane" 2>/dev/null; then
  echo "FAIL app died"
else
  echo "PASS app alive"
fi
tmux kill-session -t "$sess" 2>/dev/null || true
