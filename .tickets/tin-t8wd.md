---
id: tin-t8wd
status: closed
deps: []
links: [tin-p8k2]
created: 2026-09-16T00:00:00Z
type: feature
priority: 1
assignee: Nick Fisher
tags: [tui, terminal, emulator, parsing]
---
# Phase 1 — pure-Dart terminal emulator (state and parsing)

## Context

`/term` (docs/features/terminal_panel_plan.md) needs an in-process terminal
model that owns child output: incremental byte parsing, grids, modes,
scrollback, damage tracking, and query replies. Nothing in the repo does this
today — `test/virtual_terminal.dart` is a rendering-pipeline test harness only
and must never become the production emulator.

Phase 1 only: no input encoder, no renderer, no controller, no `/term`
registration, no PTY changes, no third-party packages. Pure Dart; no Screen,
filesystem, process, or timer dependencies.

## Proposal

`packages/tina_console/lib/src/terminal/terminal_emulator.dart` +
terminal state types, with the plan's public surface: `feed(List<int>)`,
`resize(rows, cols)`, `reset()`, a read-only viewport/state snapshot, and
`takeDamage()`. `feed` returns reply bytes and title/bell events.

Behaviours (plan Phase 1 table):

- Text/control: incremental UTF-8 (malformed → U+FFFD, never crash, never
  desync), CR, LF/VT/FF, BS, HT, BEL→bell event, default tab stops every 8.
- Cursor: CSI A/B/C/D/E/F/G/H/f/d, save/restore (ESC 7/8, CSI s/u), index /
  reverse index / next line (ESC D/M/E), DECSC/DECRC semantics, clamped,
  margins respected.
- Editing: CSI J/K/X, ICH/DCH (@/P), IL/DL (L/M), SU/SD (S/T), DECSTBM (r),
  full-screen scroll adds primary history; partial-region scroll does not.
- Attributes: SGR reset, bold, faint, italic, underline, inverse, conceal,
  strike, fg/bg 16/256/RGB, selective resets (22/23/24/27/28/29/39/49...).
- Modes: IRM (4), DECOM (6), DECAWM (7), DECTCEM (25), DECCKM (1), DECSCNM
  (5), DECARM? (no — application keypad ESC = / ESC >), DECCKM, bracketed
  paste (2004), focus reporting (1004), alt-screen DECSET/DECRST
  47/1047/1048/1049 with their distinct save/clear/restore semantics; primary
  history survives alt-screen use.
- Character sets: G0/G1 designation of the DEC Special Graphics set, SI/SO
  selection; line-drawing borders render as their Unicode box glyphs.
- Queries: DSR 5 (device status OK) and DSR 6 (CPR, 1-based, origin-aware);
  DA1 → documented conservative response.
- Strings: OSC/DCS/SOS/PM/APC consumed; OSC 0/2 → sanitized title event; OSC
  52 (clipboard), 8 (hyperlinks), 1337 images, and outer-terminal commands
  (xterm Termcap/Terminfo) have no side effects.
- Reset: RIS restores power-on state (both screens cleared, all modes off,
  tab stops reset, scrollback kept per plan).

Parsing limits: persistent state machine across chunks; sequence cap 4096
bytes; ≤ 32 CSI params; overflow discards through the terminator; CAN/SUB
abort the current sequence; unknown completed sequences ignored; discarded
payload never rendered as text.

State limits: bounded scrollback — default 10,000 rows AND 1,000,000 stored
cells (cells = sum of the row's cluster count), evicting oldest rows when
either is exceeded; injectable limits for tests. Cells store cluster text,
width, continuation marker, attributes; combining marks per cell capped at
64 code points, further marks replace the last (no unbounded cell growth).
Wide glyphs keep both halves consistent on erase/overwrite/resize.

Resize: crop/pad both grids without reflow, clamp cursor and saved cursor,
clear orphan continuation cells, reset margins to full screen, add default
tab stops (every 8) in new columns; never invent history from cropped rows.
Zero geometry never reaches the emulator (caller's duty; resize validates
positivity defensively).

Acceptance harness: table-driven fixtures with hand-written expected grids as
the oracle (production parser never asserts its own output); every fixture
replayed three ways — one chunk, byte-by-byte, and at every split point;
split-point replay is what catches persistent-state-machine bugs.

## Acceptance

- [x] Public surface: `feed`, `resize`, `reset`, snapshot, `takeDamage`; no
      Screen/fs/process/timer deps; console width conventions used.
- [x] Grids/cells: primary + alternate, cluster/width/continuation/attrs,
      DECSC/DECRC, margins, tab stops, SGR, modes, bounded scrollback
      (row AND cell limits, injectable).
- [x] Wide-glyph halves cleared on erase/overwrite/resize; combining marks
      capped at 64 per cell.
- [x] Text/control family above (UTF-8 replacement, C0, tabs).
- [x] Cursor family above (all listed CSI + ESC forms, clamped).
- [x] Editing family above (J/K/X/@/P/L/M/S/T/r + scroll-history rule).
- [x] SGR attributes family above incl. selective resets.
- [x] Modes family above (IRM, origin, wrap, cursor visibility, app keypad/
      cursor, bracketed paste, focus).
- [x] Alt-screen 47/1047/1048/1049 semantics; primary history survives.
- [x] DEC line drawing + SI/SO.
- [x] Queries: DSR 5/6, DA1; replies reflect active coordinates.
- [x] OSC/DCS/SOS/PM/APC consumed; title 0/2 sanitized event; RIS.
- [x] Parser limits: 4096-byte cap, 32 CSI params, CAN/SUB abort, unknown
      sequences ignored, split-sequence correctness.
- [x] Scrollback bounded + eviction; full-screen-primary-scroll-only history.
- [x] Resize rules above; damage tracked by `takeDamage()`.
- [x] Fixtures replayed one-chunk / byte-by-byte / every split.
