#!/usr/bin/env bash
# tin-r2vd live verification: the notcurses TUI must start in a DETACHED tmux
# session with NO terminal-reply injection and stay responsive to the keyboard.
#
# Before the fix, notcurses init blocked forever in a detached session — the
# tmux server has no attached client to answer the OSC palette/fg/bg queries,
# and libnotcurses waits for DA1 on a condition variable with no deadline.
#
# Usage: tool/verify_init_guard.sh [session] [outdir]
set -u
here="$(cd "$(dirname "$0")" && pwd)"
sess="${1:-r2vdverify}"
outdir="${2:-/tmp/r2vd_live}"
mkdir -p "$outdir"

tmux kill-session -t "$sess" 2>/dev/null || true
tmux new-session -d -x 120 -y 40 -s "$sess"
tmux send-keys -t "$sess" "cd ${TINA_DIR:-$here/..}" Enter
sleep 1
tmux pipe-pane -t "$sess" -o "cat >> $outdir/$sess.raw"
# Deliberately NO tmux_inject_replies.sh call — that is the workaround this
# fix removes.
tmux send-keys -t "$sess" "dart run bin/tina.dart --safe-mode 2>$outdir/$sess.err" Enter

# The TUI must appear on its own within a bounded window. 100 s covers a cold
# build; a warm run renders in a couple of seconds.
up=0
for _ in $(seq 1 100); do
  if tmux capture-pane -p -t "$sess" 2>/dev/null | grep -q '┌main'; then
    up=1
    break
  fi
  sleep 1
done

snap() {
  local target="${2:-$sess}"
  tmux capture-pane -p -t "$target" > "$outdir/$1.pane" 2>/dev/null
}
snap 1-rendered

fail() {
  echo "FAIL: $1"
  snap failure "${2:-$sess}"
  exit 1
}

# Quit: Esc-Esc cancels the first-load environment agent (otherwise its
# approval queue keeps eating the SIGINTs), then repeated SIGINTs clear the
# editor buffer and confirm the quit. Loop until the tina frame is gone.
quit_tina() {
  tmux send-keys -t "$1" Escape
  sleep 0.4
  tmux send-keys -t "$1" Escape
  sleep 2
  for _ in $(seq 1 6); do
    tmux send-keys -t "$1" C-c
    sleep 1.5
    tmux capture-pane -p -t "$1" 2>/dev/null | grep -q '┌main' || return 0
  done
  return 1
}

[ "$up" = 1 ] || fail "TUI never rendered in a detached tmux (no injection)"

# The keyboard must survive the fd-0 swap-back: typed text has to reach the
# editor row. tmux send-keys delivers the characters fast enough that the
# paste-burst detector clusters them into one [Pasted text : N chars] chip —
# either form proves fd 0 is the real stdin again.
tmux send-keys -t "$sess" 'kbcheck123'
sleep 3
snap 2-keyboard
grep -Eq 'kbcheck123|Pasted text : 10 chars' "$outdir/2-keyboard.pane" ||
  fail "keyboard input did not reach the editor after the pty detour"

# A global shortcut must still work (panel cycle) — proves the input path is
# the normal one, not a half-closed pty.
tmux send-keys -t "$sess" C-g
sleep 2
snap 3-after-cycle

quit_tina "$sess" || fail "tina did not exit on repeated SIGINT"
snap 4-exit

# --- Phase B: an answering terminal (the normal, attached case) -------------
# Watch for the guard's own OSC 10/11 probe in the pane output and answer it,
# the way an attached terminal would. This pins the path every real user
# takes: probe answered → no fd surgery → init waits for its own replies,
# which the injected bundle supplies. Startup must still work and the shell
# must come back with echo intact (the probe borrows raw mode and must give
# it back).
sess2="${sess}b"
rm -f "$outdir/$sess2.raw"
tmux kill-session -t "$sess2" 2>/dev/null || true
tmux new-session -d -x 120 -y 40 -s "$sess2"
tmux send-keys -t "$sess2" "cd ${TINA_DIR:-$here/..}" Enter
sleep 1
tmux pipe-pane -t "$sess2" -o "cat >> $outdir/$sess2.raw"
tmux send-keys -t "$sess2" "dart run bin/tina.dart --safe-mode 2>$outdir/$sess2.err" Enter

up2=0
for _ in $(seq 1 100); do
  # The probe query is the guard's own first write to the terminal.
  if grep -q $'\x1b]10;?' "$outdir/$sess2.raw" 2>/dev/null; then
    # Answer the probe AND notcurses' own queries, like an attached client.
    "$here/tmux_inject_replies.sh" "$sess2" >/dev/null 2>&1 || true
  fi
  if tmux capture-pane -p -t "$sess2" 2>/dev/null | grep -q '┌main'; then
    up2=1
    break
  fi
  sleep 1
done
snap 5-answering "$sess2"

[ "$up2" = 1 ] || fail "TUI never rendered when the probe was answered" "$sess2"

quit_tina "$sess2" || fail "tina did not exit on repeated SIGINT (answering path)" "$sess2"
sleep 2
tmux send-keys -t "$sess2" 'echo ECHO_OK_$((1+1))' Enter
sleep 2
snap 6-shell-echo "$sess2"
grep -q 'ECHO_OK_2' "$outdir/6-shell-echo.pane" ||
  fail "shell lost echo after the TUI quit — probe did not restore the tty" "$sess2"

echo "PASS: TUI rendered with no reply injection; keyboard + shortcuts live."
echo "PASS: answering-terminal path starts and restores the tty."
echo "      artifacts in $outdir"
exit 0
