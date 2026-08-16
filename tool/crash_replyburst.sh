#!/usr/bin/env bash
# tin-3x9v hunt, reply-burst variant. The two recorded crashes both ran in the
# 120x40 harness WITH the tin-r2vd reply injection in play — and on 2026-08-15
# that injection fired on a fixed sleep, so it could land mid-run rather than
# inside notcurses' init window. tmux_inject_replies.sh claims "stray duplicates
# of the replies are harmless" — unverified. This harness tests exactly that:
# the full reply bundle is re-injected MID-RUN (at 12 s / 30 s / 55 s into the
# turn — during the paced stream, during the streaming bash tool call, and in
# the tail) while keys are hammered. Any run that dies natively prints the pane.
#
# Usage: tool/crash_replyburst.sh [runs] [outdir]
# Needs: the stub server on 127.0.0.1:8907 with scenario crash_stream2, and a
# stub HOME at /tmp/stubhome (a ~/.tina/config pointing provider stub at the
# stub server) — the real ~/.tina/config is on a read-only mount in the sweep
# sandbox, so the provider is switched by overriding HOME for the app, never by
# editing the user's config.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
runs="${1:-3}"
outdir="${2:-/tmp/crash_replyburst}"
mkdir -p "$outdir"
sess="crashrb"
stubhome="${STUB_HOME:-/tmp/stubhome}"

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

  # Replies for the init window (the app must come up).
  for _ in $(seq 1 120); do
    grep -q "1049h" "$outdir/$run_id.raw" 2>/dev/null && break
    sleep 1
  done
  TMUX_INJECT_SLEEP=0 "$here/tmux_inject_replies.sh" "$sess" >/dev/null 2>&1 || true
  sleep 8
  tmux send-keys -t "$sess" -l "Summarize the repository layout."
  sleep 1
  tmux send-keys -t "$sess" Enter

  # Keys every second; the full reply bundle re-fires at 12 s / 30 s / 55 s.
  for i in $(seq 1 60); do
    sleep 1
    tmux send-keys -t "$sess" y 2>/dev/null || true
    case "$i" in
      12|30|55) TMUX_INJECT_SLEEP=0 "$here/tmux_inject_replies.sh" "$sess" >/dev/null 2>&1 || true ;;
    esac
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
