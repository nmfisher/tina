#!/usr/bin/env bash
# tin-q4vz live repro: real app, stub provider, paste the 6 KB corpus via
# tmux, submit, capture pane + raw output stream.
# Usage: tool/q4vz_live.sh [run-id]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

run="${1:-live}"
outdir="/tmp/q4vz_live/$run"
mkdir -p "$outdir"
sess="q4vzl"
stubhome="${STUB_HOME:-/tmp/stubhome}"
body="${BODY:-/tmp/paste5k.txt}"

curl -s -m 2 -X POST http://127.0.0.1:8907/__reset >/dev/null || true
tmux kill-server >/dev/null 2>&1 || true
sleep 1
rm -f /workspace/examples/workspace/.tina/environment/tracking.json
rm -f /workspace/examples/workspace/ENVIRONMENT.md
tmux new-session -d -x 120 -y 40 -s "$sess"
tmux send-keys -t "$sess" "cd /workspace/examples/workspace" Enter
sleep 1
tmux pipe-pane -t "$sess" -o "cat >> $outdir/raw.log"
tmux send-keys -t "$sess" "HOME=$stubhome dart run /workspace/bin/tina.dart" Enter

# Wait for the app to enter the alt screen, then unblock notcurses init.
for _ in $(seq 1 90); do
  grep -q "1049h" "$outdir/raw.log" 2>/dev/null && break
  sleep 1
done
TMUX_INJECT_SLEEP=0 "$here/tmux_inject_replies.sh" "$sess" >/dev/null 2>&1 || true

# Wait for paint: the frame border appears in the pane.
for _ in $(seq 1 40); do
  tmux capture-pane -p -t "$sess" > "$outdir/pane_boot.txt"
  grep -q 'main (stub' "$outdir/pane_boot.txt" && break
  sleep 1
done
sleep 2

# Paste + submit.
tmux load-buffer "$body"
tmux paste-buffer -t "$sess"
sleep 2
tmux send-keys -t "$sess" Enter
sleep 6

tmux capture-pane -p -t "$sess" > "$outdir/pane_final.txt"
cp "$outdir/raw.log" "$outdir/raw_copy.log" 2>/dev/null || true

python3 - "$outdir/pane_final.txt" <<'EOF'
import sys
rows = open(sys.argv[1], errors='replace').read().split('\n')
bad = []
for i, r in enumerate(rows):
    if not r.strip():
        continue
    if 1 <= i <= 38 and r[:1] not in ('│', '┌', '└', ''):
        bad.append((i, r[:56]))
print(f'borderless content rows: {len(bad)}')
for i, r in bad[:16]:
    print(f'  row {i}: {r!r}')
for i, r in enumerate(rows):
    if 'long-toke ' in r:
        print(f'GLYPH DROP at row {i}: {r[:64]!r}')
EOF
tmux kill-server >/dev/null 2>&1 || true
