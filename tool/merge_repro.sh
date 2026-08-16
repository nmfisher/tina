#!/usr/bin/env bash
# tin-m2vq repro harness: sustained resize storm mid-stream, then STOP and see
# whether the merged-row artifact persists once the pane is left alone.
#
# Usage: tool/merge_repro.sh [storm_secs] [settle_secs] [preapprove]
#   preapprove 1 (default) approves the bash call first and storms during the
#   pure streaming phase; 0 storms right after the prompt is submitted, so the
#   storm overlaps the approval phase and the approval→stream transition — the
#   timing tool/crash_resize.sh uses, which is where the merge was seen.
# Needs: the stub server on 127.0.0.1:8907 with scenario crash_stream2 and a
# stub HOME at /tmp/stubhome (see crash_replyburst.sh).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
storm_secs="${1:-30}"
settle_secs="${2:-10}"
preapprove="${3:-1}"
outdir=/tmp/merge_repro
mkdir -p "$outdir"
sess="mrg"
stubhome="${STUB_HOME:-/tmp/stubhome}"
run_id="$(date +%H%M%S)"

curl -s -X POST "http://127.0.0.1:8907/__reset" >/dev/null 2>&1 || true
tmux kill-server >/dev/null 2>&1 || true
sleep 1
rm -f /workspace/examples/workspace/.tina/environment/tracking.json
rm -f /workspace/examples/workspace/ENVIRONMENT.md
rm -f "$outdir/$run_id.raw"
tmux new-session -d -x 120 -y 40 -s "$sess"
tmux send-keys -t "$sess" "cd /workspace/examples/workspace" Enter
sleep 1
tmux pipe-pane -t "$sess" -o "cat >> $outdir/$run_id.raw"
tmux send-keys -t "$sess" "HOME=$stubhome dart run /workspace/bin/tina.dart" Enter
for _ in $(seq 1 120); do
  grep -q "1049h" "$outdir/$run_id.raw" 2>/dev/null && break
  sleep 1
done
TMUX_INJECT_SLEEP=0 "$here/tmux_inject_replies.sh" "$sess" >/dev/null 2>&1 || true
sleep 8
tmux send-keys -t "$sess" -l "Summarize the repository layout."
sleep 1
tmux send-keys -t "$sess" Enter
if [ "$preapprove" = "1" ]; then
  for _ in $(seq 1 20); do sleep 1; tmux send-keys -t "$sess" y; done
  sleep 4
fi

# Sustained storm: geometry cycle every 0.4 s, keys every 0.8 s.
geos=("120x40" "80x24" "60x15" "200x50" "80x24" "120x40")
end=$((SECONDS + storm_secs))
i=0
while [ "$SECONDS" -lt "$end" ]; do
  g="${geos[$((i % ${#geos[@]}))]}"
  tmux resize-window -t "$sess" -x "${g%x*}" -y "${g#*x}" 2>/dev/null || true
  if [ $((i % 2)) -eq 0 ]; then tmux send-keys -t "$sess" y 2>/dev/null || true; fi
  sleep 0.4
  i=$((i + 1))
  tmux has-session -t "$sess" 2>/dev/null || break
done
tmux resize-window -t "$sess" -x 120 -y 40 2>/dev/null || true

tmux capture-pane -p -t "$sess" > "$outdir/${run_id}_stormEnd.pane"
echo "merged rows at storm end:      $(grep -cE 'streamed line [0-9]+[a-z]' "$outdir/${run_id}_stormEnd.pane")"
sleep "$settle_secs"
tmux capture-pane -p -t "$sess" > "$outdir/${run_id}_settled.pane"
echo "merged rows after ${settle_secs}s settle: $(grep -cE 'streamed line [0-9]+[a-z]' "$outdir/${run_id}_settled.pane")"
grep -nE 'streamed line [0-9]+[a-z]' "$outdir/${run_id}_stormEnd.pane" | head -3
grep -nE 'streamed line [0-9]+[a-z]' "$outdir/${run_id}_settled.pane" | head -3
tmux kill-server >/dev/null 2>&1 || true
