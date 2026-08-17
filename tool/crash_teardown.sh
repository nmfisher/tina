#!/usr/bin/env bash
# tin-j3mk hunt: teardown use-after-free. emergencyTerminalRestore() (SIGTERM/
# SIGHUP, any error escaping run(), zone guard) calls screen.leaveAltScreen()
# -> notcurses_stop WITHOUT first disposing the input backend — the native
# input pump thread is still polling notcurses_get_nblock(nc) and SIGSEGVs on
# the freed context (recorded frame: notcurses_stdplane).
#
# The window needs the pump thread mid-get_nblock when stop lands, so the
# terminal-reply bundle (4837 events over ~200 ms, the same burst
# tmux_inject_replies.sh fires) keeps it busy while SIGTERM arrives.
#
# Usage: tool/crash_teardown.sh [runs] [outdir]
# Variants (TEARDOWN_MODE): term-burst (default) | term-flood | term-idle |
#                           quit-burst
set -u
here="$(cd "$(dirname "$0")" && pwd)"
runs="${1:-3}"
outdir="${2:-/tmp/crash_teardown}"
mode="${TEARDOWN_MODE:-term-burst}"
mkdir -p "$outdir"
sess="tear"
stubhome="${STUB_HOME:-/tmp/stubhome}"

for run in $(seq 1 "$runs"); do
  run_id="$(date +%H%M%S)_${run}_${mode}"
  tmux kill-server >/dev/null 2>&1 || true
  sleep 1
  tmux kill-session -t "$sess" >/dev/null 2>&1 || true
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
  tmux send-keys -t "$sess" "HOME=$stubhome dart run /workspace/bin/tina.dart" Enter

  # Wait for the alt-screen enter, then give the TUI a beat to finish init.
  for _ in $(seq 1 120); do
    grep -q "1049h" "$outdir/$run_id.raw" 2>/dev/null && break
    sleep 1
  done
  sleep 8

  case "$mode" in
    term-burst)
      # Reply burst in the background; SIGTERM lands ~150 ms in, while the
      # pump thread is inside notcurses_get_nblock draining the bundle.
      TMUX_INJECT_SLEEP=0 "$here/tmux_inject_replies.sh" "$sess" \
        >/dev/null 2>&1 &
      inj=$!
      sleep 0.15
      pkill -TERM -f "bin/tina.dart" 2>/dev/null || true
      wait $inj 2>/dev/null || true
      ;;
    term-flood)
      # Continuous keystroke flood (every ~15 ms for ~4 s) so the pump thread
      # is perpetually cycling poll -> get_nblock; SIGTERM lands mid-flood.
      (
        end=$((SECONDS + 4))
        while [ $SECONDS -lt $end ]; do
          tmux send-keys -t "$sess" -l "x" 2>/dev/null || break
          sleep 0.015
        done
      ) &
      flood=$!
      sleep 1
      pkill -TERM -f "bin/tina.dart" 2>/dev/null || true
      wait $flood 2>/dev/null || true
      ;;
    term-idle)
      pkill -TERM -f "bin/tina.dart" 2>/dev/null || true
      ;;
    quit-burst)
      # Control: the NORMAL quit path disposes the input backend before
      # notcurses_stop — this variant must never crash.
      TMUX_INJECT_SLEEP=0 "$here/tmux_inject_replies.sh" "$sess" \
        >/dev/null 2>&1 &
      sleep 0.15
      tmux send-keys -t "$sess" Escape
      sleep 0.2
      tmux send-keys -t "$sess" -l "y"  # confirm quit if asked
      sleep 0.2
      tmux send-keys -t "$sess" -l "/quit"
      sleep 0.2
      tmux send-keys -t "$sess" Enter
      wait 2>/dev/null || true
      ;;
  esac

  sleep 5
  tmux capture-pane -p -t "$sess" > "$outdir/$run_id.pane" 2>/dev/null || true
  if grep -qE "Segmentation|SIGSEGV|Aborted|core dumped" "$outdir/$run_id.pane"; then
    echo "RUN $run_id ($mode): CRASH"
  else
    echo "RUN $run_id ($mode): clean"
  fi
done
