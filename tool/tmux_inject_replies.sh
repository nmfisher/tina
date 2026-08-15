#!/usr/bin/env bash
# Inject the terminal replies notcurses blocks on into a detached tmux pane
# (workaround for tin-r2vd). Notcurses init sends ~2.8 KB of terminal queries:
# CPR, DA1/DA2, XTVERSION, XTGETTCAP, 256x OSC 4 palette, OSC 10/11, DECRPM
# 2026/1016, kitty keyboard (XTMODKEYS, flags) and graphics, XTWINOPS.
#
# Two problems on this host (tmux 3.4, vendored notcurses 3.0.17):
# 1. Detached tmux answers DA1/DA2/XTVERSION/CPR/XTWINOPS itself, but NOT the
#    OSC 4 palette, OSC 10/11, DECRPM, XTGETTCAP or kitty graphics queries,
#    so init blocks waiting for those replies.
# 2. The vendored notcurses input automaton cannot parse tmux's own DA1 reply
#    "\e[?1;2;4c" (numeric-trie collision — verified with a unit test against
#    the automaton), so even tmux's DA1 answer leaves initdata incomplete and
#    notcurses_init hangs forever.
# The injection therefore provides the missing replies AND a matchable DA1
# ("\e[?62;c" — VT220 — which the automaton's "[?\N;\Dc" pattern accepts).
#
# Delivery: pty direction matters — writing to the pane's pty SLAVE is the
# OUTPUT path (lands on the pane screen), not the input queue. Input reaches
# the pane only via the MASTER, i.e. tmux's own write path. `tmux send-keys
# -H` delivers nothing on this host's tmux 3.4 (tested), so the bytes are
# sent as named keys: "Escape" for ESC, literal chars otherwise, "\;" for
# a literal semicolon (bare ";" is a tmux command separator).
#
# Run this AFTER launching tina in the pane (it may also be re-run later —
# stray duplicates of the replies are harmless):
#
#   tmux new-session -d -x 120 -y 40 -s sweep
#   tmux send-keys -t sweep "dart run bin/tina.dart" Enter
#   tool/tmux_inject_replies.sh sweep
#
# Usage: tool/tmux_inject_replies.sh <session> [<pane>]
set -euo pipefail

session="${1:?usage: tmux_inject_replies.sh <session> [pane]}"
pane="${2:-}"

# Wait for the notcurses query burst to be written. dart run needs a moment to
# start the app; then notcurses writes its queries and blocks reading.
sleep 4

target="$session"
[ -n "$pane" ] && target="$session.$pane"

# Build the reply bytes, then send them as tmux key arguments.
python3 - "$target" <<'EOF'
import subprocess, sys, time
target = sys.argv[1]

base = [0x000000,0x800000,0x008000,0x808000,0x000080,0x800080,0x008080,0xc0c0c0,
        0x808080,0xff0000,0x00ff00,0xffff00,0x0000ff,0xff00ff,0x00ffff,0xffffff]
cube = [0x0000,0x5f5f,0x8787,0xafaf,0xd7d7,0xffff]
gray = [0x0808,0x1212,0x1c1c,0x2626,0x3030,0x3a3a,0x4444,0x4e4e,0x5858,0x6262,
        0x6c6c,0x7676,0x8080,0x8a8a,0x9494,0x9e9e,0xa8a8,0xb2b2,0xbcbc,0xc6c6,
        0xd0d0,0xdadad,0xe4e4,0xeeee]
pal = list(base)
for r in cube:
    for g in cube:
        for b in cube:
            pal.append((r << 16) | (g << 8) | b)
for g in gray:
    pal.append((g << 16) | (g << 8) | g)

def osc4(n, rgb):
    r = (rgb >> 16) & 0xffff; g = (rgb >> 8) & 0xffff; b = rgb & 0xffff
    return f'\x1b]4;{n};rgb:{r:04x}/{g:04x}/{b:04x}\x1b\\'

out = []
# DA1 first: it is the reply that completes notcurses' init response phase.
out += ['\x1b[?62;c']                       # DA1 (VT220) — automaton-matchable
out += ['\x1b[1;1R']                         # CPR
for n, rgb in enumerate(pal):
    out.append(osc4(n, rgb))
out += ['\x1b]10;rgb:ffff/ffff/ffff\x1b\\']  # OSC 10 fg
out += ['\x1b]11;rgb:0000/0000/0000\x1b\\']  # OSC 11 bg
out += ['\x1b[?2026;1$y', '\x1b[?1016;1$y']  # DECRPM 2026 (kitty kb), 1016 (SGR mouse)
out += ['\x1b[?1;3;256S', '\x1b[?1;3;1024S'] # XTMODKEYS (matches fail; replay is harmless)
out += ['\x1b[?1u']                          # kitty keyboard flags
out += ['\x1b_Gi=1;OK\x1b\\']                # kitty graphics
out += ['\x1bP1+r544e;787465726d2d323536636f6c6f72\x1b\\']  # XTGETTCAP TN=xterm-256color
out += ['\x1bP1+r524742;31\x1b\\']           # XTGETTCAP RGB=1
out += ['\x1bP0+r687061\x1b\\']              # XTGETTCAP hpa missing
out += ['\x1b[4;1;1;80;120t', '\x1b[8;40;120t']  # XTWINOPS 14 + 18

# Map each reply to tmux key arguments: ESC -> "Escape", ';' -> "\;", else the
# literal byte. Backslash (ST terminator) passes as a plain arg.
def keyargs(s):
    args = []
    for ch in s:
        if ch == '\x1b':
            args.append('Escape')
        elif ch == ';':
            args.append('\\;')
        else:
            args.append(ch)
    return args

cmd = ['tmux', 'send-keys', '-t', target]
n = 0
for reply in out:
    for arg in keyargs(reply):
        cmd.append(arg)
        n += 1
        if n >= 40:  # keep each tmux invocation small
            subprocess.run(cmd, check=True)
            cmd = ['tmux', 'send-keys', '-t', target]
            n = 0
if n:
    subprocess.run(cmd, check=True)
print(f'injected {len(out)} replies')
EOF
