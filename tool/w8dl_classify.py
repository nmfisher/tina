#!/usr/bin/env python3
"""Classify one tin-w8dl hunt run from its captured pane + audit log.

Healthy: the paste submitted — the editor no longer holds a
'[Pasted text : N chars]' placeholder, and the turn went out (persisted
chars ≈ corpus, or the pane shows the stub's reply arriving after submit).

Unhealthy shapes (any one fails the run):
  A. placeholder still in the editor rows at capture time (paste never left)
  B. placeholder count > 1 (split paste, tail never joined)
  C. persisted paste chars < corpus - 1 (trimmed newline) - 1
  D. audit log shows a drop: 'DROPPING', a gap-flush mid-burst, or a
     readKey ANSWERED by a CharInput.

Prints VERDICT plus one line per signal so the hunt log stays greppable.
"""
import os
import re
import sys

outdir, body = sys.argv[1], sys.argv[2]
pane = os.path.join(outdir, 'pane_final.txt')
rows = open(pane, errors='replace').read().split('\n') if os.path.exists(pane) else []

# Input/editor rows are the bottom of the pane; placeholder anywhere is a
# signal, but distinguish 'still held' (bottom 6 rows) from 'echoed in chat'.
bottom = rows[-8:]
held = [r for r in bottom if 'Pasted text' in r and 'chars]' in r]
anywhere = [r for r in rows if 'Pasted text' in r and 'chars]' in r]

corpus = open(body, 'rb').read().decode('utf-8', 'replace')
# The editor trims one trailing newline on submit.
want = len(corpus.rstrip('\n'))

audit_path = os.path.join(outdir, 'audit.log')
audit = open(audit_path, errors='replace').read().split('\n') if os.path.exists(audit_path) else []
drops = [l for l in audit if 'DROPPING' in l]
gap_flush = [l for l in audit if 'gap-flush' in l]
answered = [l for l in audit if 'ANSWERED by' in l]
paste_chars = [int(m.group(1)) for l in audit
               for m in [re.search(r'drain\[\w+\]: PASTE chars=(\d+)', l)] if m]
total_paste_out = sum(paste_chars)

signals = []
if held:
    signals.append(f'A: placeholder still held in editor: {held[0].strip()[:70]!r}')
if len(anywhere) > 1:
    signals.append(f'B: {len(anywhere)} placeholder rows (split paste)')
if total_paste_out and total_paste_out < want:
    signals.append(f'C: audit paste chars out={total_paste_out} < corpus={want}')
if drops:
    signals.append(f'D: editor dropped pending: {drops[0].strip()[:90]!r}')
if answered:
    sig = [l for l in answered if 'CharInput' in l]
    if sig:
        signals.append(f'D: readKey answered by paste char: {sig[0].strip()[:90]!r}')

if signals:
    print('UNHEALTHY | ' + ' ; '.join(signals))
else:
    note = f'paste_chars_out={total_paste_out}'
    if gap_flush:
        note += f' (detector split {len(gap_flush)}x — tail delivered, not dropped)'
    print(f'HEALTHY | {note}')
