#!/usr/bin/env bash
# tin-3x9v hunt, high-rate OSC variant. Hypothesis under test: the native input
# pump thread calls notcurses_get_nblock(nc) while the main isolate renders the
# same notcurses context — notcurses documents one context per thread. The
# overlapping state is the palette / default colors: the input automaton writes
# them when it parses an OSC 4 / OSC 10 / OSC 11 reply, and rasterize reads
# them during render. The 2026-08-15 crashes both ran with the tin-r2vd reply
# injection in play; this harness narrows the injection to exactly those
# palette-touching replies and fires them continuously (~10 Hz) while a bash
# tool call streams and keys are pressed — the widest the race window can get.
#
# Usage: tool/crash_oscstress.sh [runs] [outdir]
# Needs: the stub server on 127.0.0.1:8907 with scenario crash_stream2 and a
# stub HOME at /tmp/stubhome (see crash_replyburst.sh).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
runs="${1:-2}"
outdir="${2:-/tmp/crash_oscstress}"
mkdir -p "$outdir"
sess="crashosc"
stubhome="${STUB_HOME:-/tmp/stubhome}"

# One probe: an OSC 4 palette write, an OSC 11 background write, a DA1. Sent as
# tmux key args (Escape / literal chars / \; for a literal semicolon).
probe_args=("Escape" "]" "4" "\;" "5" "\;" "r" "g" "b" ":" "8" "7" "0" "8" "/" "a" "f" "a" "f" "/" "d" "7" "d" "7" "Escape" "\\" "Escape" "]" "1" "1" "\;" "r" "g" "b" ":" "0" "0" "0" "0" "/" "0" "0" "0" "0" "/" "0" "0" "0" "0" "Escape" "\\")

for run in $(seq 1 "$runs"); do
  run_id="$(date +%H%M%S)_$run"
  curl -s -X POST "http://127.0.0.1:8907/__reset" >/dev/null 2>&1 || true
  tmux kill-server >/dev/null 2>&1 || true
  sleep 1
  tmux kill-session -t "$sess" >/dev/null 2>&1 || true
  rm -f /workspace/examples/workspace/.tina/environment/tracking.json
  rm -f /workspace/examples/workspace/ENVIRONMENT.md
  if ! tmux new-session -d -x 120 -y 40 -s "$sess" 2>/dev/null; then
    sleep 1; tmux new-session -d -x 120 -y 40 -s "$sess"
  fi
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

  # ~10 Hz palette probes for 45 s, a keystroke every ~0.5 s throughout.
  # No -l: "Escape" must be read as the ESC key, per tmux_inject_replies.sh.
  for i in $(seq 1 450); do
    tmux send-keys -t "$sess" "${probe_args[@]}" 2>/dev/null || true
    if [ $((i % 5)) -eq 0 ]; then
      tmux send-keys -t "$sess" y 2>/dev/null || true
    fi
    sleep 0.1
    tmux has-session -t "$sess" 2>/dev/null || break
  done
  tmux capture-pane -p -t "$sess" > "$outdir/$run_id.pane" 2>/dev/null || true
  if grep -q "Segmentation\|Killed\|SIGSEGV" "$outdir/$run_id.pane" 2>/dev/null; then
    echo "RUN $run_id: APP DEAD"
    grep -n "Segmentation\|SIGSEGV\|Killed" "$outdir/$run_id.pane" | head -3
  else
    echo "RUN $run_id: alive"
  fi
  tmux kill-server >/dev/null 2>&1 || true
done
