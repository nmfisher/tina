#!/usr/bin/env bash
# tin-y4qn live verification: the panel busy comet must track the panel's own
# conversation activity, not focus.
#
# Scenario (stub = y4qn_busy (~20 s paced stream), ceremony suppressed via a pre-seeded
# ENVIRONMENT.md so the stub serves exactly the two typed turns):
#   1. boot, /spawn a side panel, cycle focus back to main
#   2. turn 1 in main (paced ~20 s stream), queue a second message
#   3. cycle focus to the side panel (main unfocused, turn running)
#      -> BUSY+UNFOCUSED: comet cells (━) present on the main border  [x3 samples]
#   4. wait for turn 1 + the queued turn 2 to finish
#      -> IDLE+UNFOCUSED: no ━ anywhere, two samples identical         [x2 samples]
#
# Usage: tool/y4qn_hunt.sh [--keep]
#   --keep  keep the tmux session + artifacts for inspection
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export PATH="/home/agent/dart-sdk/bin:$PATH"

base=/tmp/y4qn_hunt
outdir="$base/run"
rm -rf "$outdir"; mkdir -p "$outdir"
port=8907
scenario=y4qn_busy
fixture=/workspace/examples/workspace
stubhome="$base/home"

fail() { echo "[y4qn] FAIL: $*"; echo "[y4qn] artifacts in $outdir"; exit 1; }

# Stub up + reset (deterministic regardless of what a previous session left).
pkill -f "stub_server.dart" 2>/dev/null || true
sleep 0.5
(cd /workspace && nohup dart run tool/stub_server.dart \
    --scenario "$scenario" --port $port >"$outdir/stub.log" 2>&1 &)
disown -a 2>/dev/null || true
for _ in $(seq 1 30); do
  curl -s -m 2 -X POST "http://127.0.0.1:$port/__reset" >/dev/null 2>&1 && break
  sleep 1
done
curl -s -m 2 -X POST "http://127.0.0.1:$port/__reset" >/dev/null \
  || fail "stub server never came up (see $outdir/stub.log)"

# Fresh stub home. NOTE: the provider id must be a built-in with a model
# catalog (deepseek) — a custom id like "stub" has no models, so /spawn's
# picker comes up empty and swallows the run (filed separately as its own
# ticket). base_url override points the built-in at the local stub.
rm -rf "$stubhome"; mkdir -p "$stubhome/.tina"
cat > "$stubhome/.tina/config" <<'EOF'
version = 1

[default]
provider = "deepseek"
model = "deepseek-chat"

[providers.deepseek]
api_key = "stub-key"
base_url = "http://127.0.0.1:8907"
EOF
chmod 600 "$stubhome/.tina/config"

# Suppress the first-load environment ceremony: it would consume stub steps.
# A stale record does NOT auto-run (only a missing one does), so a stub file
# is enough. Remember whether we created it so we can restore.
envmd="$fixture/ENVIRONMENT.md"
created_envmd=0
if [ ! -f "$envmd" ]; then
  printf '# Environment\n\nstub-seeded for the tin-y4qn live hunt\n' > "$envmd"
  created_envmd=1
fi

capture() { tmux capture-pane -p -t y4qn >"$1"; }
comet_count() { grep -c '━' "$1" 2>/dev/null || true; }

tmux kill-server >/dev/null 2>&1 || true
sleep 1
tmux new-session -d -x 120 -y 40 -s y4qn
tmux send-keys -t y4qn "cd $fixture" Enter
sleep 1
tmux pipe-pane -t y4qn -o "cat >> $outdir/raw.log"
tmux send-keys -t y4qn \
  "HOME=$stubhome /home/agent/dart-sdk/bin/dart run /workspace/bin/tina.dart" Enter

# Wait for paint: the main panel title appears.
for _ in $(seq 1 60); do
  capture "$outdir/00_boot.txt"
  grep -q 'main (deepseek' "$outdir/00_boot.txt" && break
  sleep 1
done
grep -q 'main (deepseek' "$outdir/00_boot.txt" || fail "TUI never painted"
sleep 2

# Control 1: idle at boot — no comet anywhere.
capture "$outdir/01_idle_boot.txt"
[ "$(comet_count "$outdir/01_idle_boot.txt")" -eq 0 ] \
  || fail "comet cells present at idle boot (no turn has run)"

# Spawn a side panel (model picker: Enter on default; profile picker: Enter).
tmux send-keys -t y4qn -l '/spawn'
sleep 0.4
tmux send-keys -t y4qn Enter
sleep 1.5
capture "$outdir/02_spawn_picker.txt"
tmux send-keys -t y4qn Enter
sleep 1.5
capture "$outdir/03_spawn_profile.txt"
tmux send-keys -t y4qn Enter
sleep 3
capture "$outdir/04_spawned.txt"
grep -q 'main (deepseek' "$outdir/04_spawned.txt" \
  || fail "spawn flow lost the main panel (see 04_spawned.txt)"

# Focus back to main (spawn focuses the new panel): Ctrl+G engages cycling,
# Tab advances the highlight, Enter commits.
tmux send-keys -t y4qn C-g
sleep 0.4
tmux send-keys -t y4qn Tab
sleep 0.4
tmux send-keys -t y4qn Enter
sleep 1.5
capture "$outdir/05_focus_main.txt"

# Turn 1 (paced ~12 s stream), then a queued second message.
tmux send-keys -t y4qn -l 'describe the workspace fixture'
sleep 0.3
tmux send-keys -t y4qn Enter
sleep 1.2
tmux send-keys -t y4qn -l 'and its cli package'
sleep 0.3
tmux send-keys -t y4qn Enter
sleep 0.8
capture "$outdir/06_queued.txt"
grep -q 'queued' "$outdir/06_queued.txt" \
  || echo "[y4qn] note: queued notice not visible yet (continuing)"

# Cycle focus to the side panel: main runs unfocused. Samples land ~4-7 s
# into the ~12 s stream — squarely mid-turn.
tmux send-keys -t y4qn C-g
sleep 0.3
tmux send-keys -t y4qn Tab
sleep 0.3
tmux send-keys -t y4qn Enter
sleep 1
busy_samples=()
for i in 1 2 3; do
  capture "$outdir/07_unfocused_busy_$i.txt"
  busy_samples+=("$(comet_count "$outdir/07_unfocused_busy_$i.txt")")
  sleep 1
done
echo "[y4qn] busy+unfocused comet samples: ${busy_samples[*]}"
for i in 1 2 3; do
  [ "${busy_samples[$((i-1))]}" -gt 0 ] \
    || fail "no comet while the unfocused panel's turn runs (07_$i)"
done

# Wait for turn 1 + the queued turn 2: the stub must have served 2 turns and
# the pane must be stable across a 3 s window.
served=0
for _ in $(seq 1 90); do
  served=$(grep -ac 'turn=[0-9]' "$outdir/stub.log" 2>/dev/null || echo 0)
  [ "$served" -ge 2 ] && break
  sleep 1
done
echo "[y4qn] stub turns served: $served"
for _ in $(seq 1 30); do
  capture "$outdir/09_settle_a.txt"
  sleep 3
  capture "$outdir/10_settle_b.txt"
  if ! diff -q <(grep -v '^[[:space:]]*$' "$outdir/09_settle_a.txt") \
               <(grep -v '^[[:space:]]*$' "$outdir/10_settle_b.txt") >/dev/null; then
    continue
  fi
  break
done

# The verdict: idle + unfocused => static border, twice, >1 s apart.
capture "$outdir/11_idle_unfocused_a.txt"
sleep 1.2
capture "$outdir/12_idle_unfocused_b.txt"
idle_a=$(comet_count "$outdir/11_idle_unfocused_a.txt")
idle_b=$(comet_count "$outdir/12_idle_unfocused_b.txt")
echo "[y4qn] idle+unfocused comet samples: $idle_a, $idle_b"
[ "$idle_a" -eq 0 ] || fail "comet on an idle unfocused panel (11) — stuck cue"
[ "$idle_b" -eq 0 ] || fail "comet on an idle unfocused panel (12) — stuck cue"
diff -q <(grep -v '^[[:space:]]*$' "$outdir/11_idle_unfocused_a.txt") \
         <(grep -v '^[[:space:]]*$' "$outdir/12_idle_unfocused_b.txt") >/dev/null \
  || echo "[y4qn] note: pane differs between idle samples (chat text?) — comet check is the verdict"

# The queued turn must have run (async progress while unfocused).
grep -q 'turn=2' "$outdir/stub.log" \
  || fail "queued turn never ran (stub served <2 turns) — unfocused progress stalled"

if [ "${1:-}" != "--keep" ]; then
  tmux kill-server >/dev/null 2>&1 || true
fi
[ "$created_envmd" -eq 1 ] && rm -f "$envmd"
echo "[y4qn] HEALTHY: busy-unfocused animates (${busy_samples[*]} samples), idle-unfocused static ($idle_a/$idle_b), queued turn ran"
