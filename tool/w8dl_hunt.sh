#!/usr/bin/env bash
# tin-w8dl hunt: loop the 5k-paste repro (stub provider, ceremony load) until
# the truncation/swallowed-Enter recurs, with the paste-path audit log
# (TINA_PASTE_AUDIT_LOG) capturing every hop: native batches → detector
# flushes → editor routing (_pending drops, readKey answers).
#
# Usage: tool/w8dl_hunt.sh [max-runs] [--keep]
#   max-runs  default 12
#   --keep    don't tmux kill-server between runs is NOT supported (runs must
#             be identical); --keep keeps the unhealthy run's outdir on disk
#             (it always is — this flag only skips the final cleanup grep).
#
# Home policy: every 3rd run reuses the previous run's HOME (the unhealthy
# origin per the ticket: a reused HOME that already had a session). Others
# are fresh. The ceremony is forced each run (tracking.json + ENVIRONMENT.md
# deleted) so the environment stream is live when the paste lands.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export PATH="/home/agent/dart-sdk/bin:$PATH"

max="${1:-12}"
base=/tmp/w8dl_hunt
stubhome_default=/tmp/stubhome
body="${BODY:-/tmp/paste5k.txt}"
port=8907
scenario="${SCENARIO:-w8dl_ceremony}"

mkdir -p "$base"

# (Re)start the stub on our port serving the wanted scenario, so each hunt
# invocation is deterministic regardless of what a previous session left up.
stub_pid() { pgrep -f "stub_server.dart --scenario $scenario" | head -1; }
if [ -n "$(stub_pid)" ]; then
  echo "[hunt] stub already serving $scenario"
else
  pkill -f "stub_server.dart" 2>/dev/null || true
  sleep 0.5
  echo "[hunt] starting stub server (scenario $scenario, port $port)"
  (cd /workspace && nohup dart run tool/stub_server.dart \
      --scenario "$scenario" --port $port >"$base/stub.log" 2>&1 &)
  # Detach fully: an undisowned grandchild leaves this script in do_wait at
  # exit (observed: wrapper hung with the stub as its only live child).
  disown -a 2>/dev/null || true
  for _ in $(seq 1 30); do
    curl -s -m 2 -X POST "http://127.0.0.1:$port/__reset" >/dev/null 2>&1 && break
    sleep 1
  done
fi
curl -s -m 2 -X POST "http://127.0.0.1:$port/__reset" >/dev/null || {
  echo "[hunt] stub server never came up; see $base/stub.log"; exit 1; }

unhealthy=0
for i in $(seq 1 "$max"); do
  outdir="$base/run$i"
  rm -rf "$outdir"; mkdir -p "$outdir"
  stubhome="$stubhome_default"

  # Every 3rd run: reuse the previous run's home (session present).
  if [ $((i % 3)) -eq 0 ] && [ -d "$base/run$((i-1))/home" ]; then
    rm -rf "$outdir/home"
    cp -a "$base/run$((i-1))/home" "$outdir/home"
    stubhome="$outdir/home"
    echo "[hunt] run $i: REUSED home (session present)"
  else
    # Fresh home: the canonical stub config (preserved at first script run),
    # sessions cleared. /tmp/stubhome is disposable except for that config.
    rm -rf "$stubhome"
    mkdir -p "$stubhome/.tina"
    cp "$base/stub.config" "$stubhome/.tina/config"
    chmod 600 "$stubhome/.tina/config"
    echo "[hunt] run $i: fresh home"
  fi

  # Force the environment ceremony (it must stream while the paste lands).
  rm -f /workspace/examples/workspace/.tina/environment/tracking.json
  rm -f /workspace/examples/workspace/ENVIRONMENT.md

  curl -s -m 2 -X POST "http://127.0.0.1:$port/__reset" >/dev/null
  tmux kill-server >/dev/null 2>&1 || true
  sleep 1
  sess="w8dl$i"
  tmux new-session -d -x 120 -y 40 -s "$sess"
  tmux send-keys -t "$sess" "cd /workspace/examples/workspace" Enter
  sleep 1
  tmux pipe-pane -t "$sess" -o "cat >> $outdir/raw.log"
  tmux send-keys -t "$sess" \
    "HOME=$stubhome TINA_PASTE_AUDIT_LOG=$outdir/audit.log /home/agent/dart-sdk/bin/dart run /workspace/bin/tina.dart" Enter

  # Wait for alt-screen, then paint.
  for _ in $(seq 1 90); do
    grep -q "1049h" "$outdir/raw.log" 2>/dev/null && break
    sleep 1
  done
  for _ in $(seq 1 40); do
    tmux capture-pane -p -t "$sess" > "$outdir/pane_boot.txt"
    grep -q 'main (stub' "$outdir/pane_boot.txt" && break
    sleep 1
  done
  sleep 2
  tmux capture-pane -p -t "$sess" > "$outdir/pane_prepaste.txt"

  # Paste + Enter, exactly as the ticket repro.
  tmux load-buffer "$body"
  tmux paste-buffer -t "$sess"
  sleep 1.4
  tmux capture-pane -p -t "$sess" > "$outdir/pane_pasted.txt"
  sleep 0.1
  # First Enter: with the w8dl_ceremony approval open this answers the
  # prompt (modal). Second Enter (post-fix design): submits the paste.
  tmux send-keys -t "$sess" Enter
  sleep 2
  tmux send-keys -t "$sess" Enter
  sleep 6

  tmux capture-pane -p -t "$sess" > "$outdir/pane_final.txt"
  tmux kill-server >/dev/null 2>&1 || true

  # Snapshot the home for a possible next-run reuse.
  if [ "$stubhome" = "$stubhome_default" ]; then
    rm -rf "$outdir/home"; mkdir -p "$outdir/home"
    cp -a "$stubhome/.tina" "$outdir/home/.tina" 2>/dev/null || true
  fi

  verdict=$(python3 "$here/w8dl_classify.py" "$outdir" "$body")
  echo "[hunt] run $i: $verdict"
  if [[ "$verdict" == UNHEALTHY* ]]; then
    unhealthy=1
    echo "[hunt] UNHEALTHY at run $i — artifacts in $outdir"
    echo "[hunt] audit log:"
    cat "$outdir/audit.log" 2>/dev/null || echo "(no audit log!)"
    echo "[hunt] pane_final:"
    cat "$outdir/pane_final.txt"
    break
  fi
done

if [ "$unhealthy" -eq 0 ]; then
  echo "[hunt] no unhealthy run in $max runs"
fi
exit 0
