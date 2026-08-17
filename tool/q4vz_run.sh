#!/usr/bin/env bash
# tin-q4vz hunt: run the notcurses harness in a tmux pane, capture the pane,
# count borderless chat rows. Usage:
#   tool/q4vz_run.sh [--stream] [--busy] [--body FILE]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

SESSION=q4vz
GEOM=120x40
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --stream|--busy|--script) ARGS+=("$1") ;;
    --body) ARGS+=("$1" "$2"); shift ;;
    *) echo "unknown arg $1" >&2; exit 1 ;;
  esac
  shift
done

tmux kill-server >/dev/null 2>&1 || true
sleep 0.5
tmux new-session -d -x "${GEOM%x*}" -y "${GEOM#*x}" -s "$SESSION"
tmux send-keys -t "$SESSION" "cd /workspace && /home/agent/dart-sdk/bin/dart run tool/q4vz_harness.dart ${ARGS[*]+${ARGS[*]}} --log /tmp/q4vz_harness.log" Enter
TMUX_INJECT_SLEEP=5 "$here/tmux_inject_replies.sh" "$SESSION"

# Wait for the harness to finish its run phase (it idles 55 s afterwards).
for _ in $(seq 1 40); do
  if grep -q 'run complete' /tmp/q4vz_harness.log 2>/dev/null; then break; fi
  sleep 1
done
sleep 1
tmux capture-pane -p -t "$SESSION" > /tmp/q4vz_pane.txt
tmux kill-server >/dev/null 2>&1 || true

python3 - <<'EOF'
rows = open('/tmp/q4vz_pane.txt', errors='replace').read().split('\n')
bad = []
for i, r in enumerate(rows):
    if not r.strip():
        continue
    # Chat panel spans cols 0..77; content rows are 1..38.
    first = r[:1]
    if i in range(1, 39) and first not in ('│', '┌', '└', ''):
        bad.append((i, r[:60]))
print(f'borderless content rows: {len(bad)}')
for i, r in bad[:15]:
    print(f'  row {i}: {r!r}')
# glyph-drop signature
for i, r in enumerate(rows):
    if 'long-toke' in r and 'long-token' not in r:
        print(f'GLYPH DROP at row {i}: {r[:70]!r}')
EOF
