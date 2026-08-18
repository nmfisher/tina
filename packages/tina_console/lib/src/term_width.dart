// Conservative terminal cell-width accounting — the one width table behind
// every column budget in the chat emit path (tin-q4vz).
//
// Before this module existed, every budget site counted one column per UTF-16
// code unit. That under-counts real terminal layout for wide runes (a BMP CJK
// glyph is 1 code unit but 2 cells) and mis-shapes emoji clusters (ZWJ
// families, VS16 presentations). A row whose budget was honest by that table
// could still lay out wider on the real terminal, so the rasterized run
// autowrapped past the plane's right edge onto the next screen row — blanking
// the left `│` border and the first cells of the row below (the two defects
// in tin-q4vz share that root).
//
// Doctrine: **err high, never low.** Over-counting costs at most a column at
// the right edge (a run clipped early, a background pad one space short);
// under-counting wraps. Concretely:
//
// - astral code points (≥ U+10000) count 2 — every emoji is wide, and the
//   narrow astral exceptions (mathematical alphanumerics &c.) err high;
// - VS16 (U+FE0F) counts 1, not 0, so a pictographic base + VS16 totals ≥ 2
//   (what a terminal actually lays out for emoji presentation);
// - combining marks OUTSIDE the zero-width list below intentionally count 1 —
//   an unlisted mark errs high, which is safe;
// - unpaired surrogates count 1 (the plain-patch paths exclude them already;
//   counting 0 could under-count a terminal's replacement glyph);
// - ZWJ (U+200D) counts 1, not 0: measured live against tmux (tin-q4vz hunt
//   2), it lays each member of a ZWJ cluster out as its own cell — so a
//   joiner must consume budget too, or a cluster-heavy row under-counts and
//   wraps. 👨‍👩‍👧‍👦 therefore budgets 11 cells (4×2 people + 3 joiners).

/// True for a UTF-16 high surrogate.
bool _isHighSurrogate(int cu) => cu >= 0xd800 && cu <= 0xdbff;

/// True for a UTF-16 low surrogate.
bool _isLowSurrogate(int cu) => cu >= 0xdc00 && cu <= 0xdfff;

/// Size in UTF-16 code units of the code point starting at [i]: 2 for a
/// surrogate pair, else 1. Never splits a pair.
int runeSizeAt(String s, int i) {
  final cu = s.codeUnitAt(i);
  if (_isHighSurrogate(cu) && i + 1 < s.length) {
    if (_isLowSurrogate(s.codeUnitAt(i + 1))) return 2;
  }
  return 1;
}

/// Decode the code point starting at code-unit index [i]. An unpaired
/// surrogate decodes to its own value (width 1 per the doctrine above).
int codePointAt(String s, int i) {
  final cu = s.codeUnitAt(i);
  if (_isHighSurrogate(cu) && i + 1 < s.length) {
    final lo = s.codeUnitAt(i + 1);
    if (_isLowSurrogate(lo)) {
      return 0x10000 + ((cu - 0xd800) << 10) + (lo - 0xdc00);
    }
  }
  return cu;
}

/// Terminal cells occupied by the code point [cp] (see the module doctrine).
int runeWidth(int cp) {
  if (cp == 0x200d) return 1; // ZWJ — see doctrine
  if (cp == 0xfe0f) return 1; // VS16 — see doctrine
  if (cp < 0x300) return 1; // ASCII, Latin-1: the overwhelmingly common case
  if (cp >= 0x10000) return 2; // astral: emoji-wide; narrow exceptions err high
  if (_inRanges(cp, _zeroWidthRanges)) return 0;
  if (_inRanges(cp, _wideBmpRanges)) return 2;
  return 1;
}

/// Total terminal width of [s], summing [runeWidth] over its code points.
/// Treats [s] as plain content — embedded CSI escapes are NOT skipped; callers
/// that can carry ANSI use their own CSI-skipping walk and call [runeWidth]
/// per rune.
int plainWidth(String s) {
  var w = 0;
  for (var i = 0; i < s.length;) {
    w += runeWidth(codePointAt(s, i));
    i += runeSizeAt(s, i);
  }
  return w;
}

/// True when [s] contains a ZWJ cluster (U+200D) — the one rune class where
/// the terminal's layout runs WIDER than notcurses' raster model: tmux lays
/// every cluster member out as its own cell while nc composes the sequence
/// into a single wide cell (measured live, tin-q4vz hunt 2 / tin-p8k2).
///
/// This is the drift that displaces CURSOR-RELATIVE raster output: after
/// emitting such a row, the real terminal's cursor sits right of where nc
/// believes it is, so any run the raster chains onto it (an unaddressed
/// erase for the previous row's tail) lands displaced and can wrap onto the
/// next screen row, blanking the panel border. Callers that hand a
/// shrinking row to a notcurses plane use this to decide whether the erase
/// must land in its own ADDRESSED raster (tin-p8k2).
bool driftsAgainstRaster(String s) => s.contains('‍');

/// BMP ranges that occupy no cells: combining diacritics, the Bidi/inline
/// format controls (ZW*, LRM/RLM), and variation selectors VS1–VS15. VS16 is
/// deliberately absent (width 1, see doctrine).
const List<int> _zeroWidthRanges = [
  0x0300, 0x036f, // combining diacritical marks
  0x0483, 0x0489, // Cyrillic combining marks
  0x0591, 0x05bd, // Hebrew points (with the gaps below)
  0x05bf, 0x05bf,
  0x05c1, 0x05c2,
  0x05c4, 0x05c7,
  0x0610, 0x061a, // Arabic honorific / Qur'anic marks
  0x064b, 0x065f, // Arabic diacritics
  0x0670, 0x0670,
  0x06d6, 0x06dc,
  0x06df, 0x06e4,
  0x06e7, 0x06e8,
  0x06ea, 0x06ed,
  0x0711, 0x0711, // Syriac mark
  0x0730, 0x074a, // Thaana marks
  0x07a6, 0x07b0, // NKo marks
  0x07eb, 0x07f3, // ext. NKo
  0x0816, 0x0819, // Samaritan marks
  0x081b, 0x0823,
  0x0825, 0x0827,
  0x0829, 0x082d,
  0x0859, 0x085b, // Mandaic marks
  0x200b, 0x200c, // ZWSP ZWNJ
  0x200e, 0x200f, // LRM RLM
  0x2060, 0x2064, // word joiner, invisible separators
  0x206a, 0x206f, // deprecated format controls
  0x20d0, 0x20f0, // combining marks for symbols
  0xfe00, 0xfe0e, // variation selectors VS1–VS15 (VS16 = 0xfe0f → 1)
  0xfe20, 0xfe2f, // combining half marks
  0xfeff, 0xfeff, // zero-width no-break space
  0xfff9, 0xfffb, // interlinear annotation
];

/// BMP ranges rendered two cells wide: East Asian Wide/Fullwidth plus the
/// Unicode-9+ emoji-wide BMP set. Everything astral is handled above (2).
/// This list must stay conservative in the WIDE direction — a wide rune
/// missing from it under-counts and wraps (tin-q4vz); a narrow rune wrongly
/// listed over-counts, which only costs a column at the right edge.
const List<int> _wideBmpRanges = [
  0x1100, 0x115f, // Hangul Jamo choseong
  0x231a, 0x231b, // ⌚ ⌛
  0x2329, 0x232a, // 〈 〉
  0x23e9, 0x23ec, // ⏩..⏬
  0x23f0, 0x23f0, // ⏰
  0x23f3, 0x23f3, // ⏳
  0x25fd, 0x25fe, // ◽ ◾
  0x2614, 0x2615, // ☔ ☕
  0x2648, 0x2653, // zodiac
  0x267f, 0x267f, // ♿
  0x2693, 0x2693, // ⚓
  0x26a1, 0x26a1, // ⚡
  0x26aa, 0x26ab, // ⚪ ⚫
  0x26bd, 0x26be, // ⚽ ⚾
  0x26c4, 0x26c5, // ⛄ ⛅
  0x26ce, 0x26ce, // ⛎
  0x26ea, 0x26ea, // ⛪
  0x26f2, 0x26f3, // ⛲ ⛳
  0x26f5, 0x26f5, // ⛵
  0x26fa, 0x26fa, // ⛺
  0x26fd, 0x26fd, // ⛽
  0x2705, 0x2705, // ✅
  0x270a, 0x270b, // ✊ ✋
  0x2728, 0x2728, // ✨
  0x274c, 0x274c, // ❌
  0x274e, 0x274e, // ❎
  0x2753, 0x2755, // ❓ ❔ ❕
  0x2757, 0x2757, // ❗
  0x2795, 0x2797, // ➕ ➖ ➗
  0x27b0, 0x27b0, // ➰
  0x27bf, 0x27bf, // ➿
  0x2b1b, 0x2b1c, // ⬛ ⬜
  0x2b50, 0x2b50, // ⭐
  0x2b55, 0x2b55, // ⭕
  0x2e80, 0x303e, // CJK radicals .. CJK symbols (incl. 〇)
  0x3041, 0x33ff, // Hiragana, Katakana, Bopomofo, CJK compat
  0x3400, 0x4dbf, // CJK ext A
  0x4e00, 0x9fff, // CJK unified
  0xa000, 0xa4cf, // Yi
  0xa960, 0xa97f, // Hangul Jamo ext-A
  0xac00, 0xd7a3, // Hangul syllables
  0xf900, 0xfaff, // CJK compat ideographs
  0xfe10, 0xfe19, // vertical forms
  0xfe30, 0xfe6f, // CJK compat forms
  0xff00, 0xff60, // fullwidth forms
  0xffe0, 0xffe6, // fullwidth signs
];

/// Linear membership scan over a flat [lo, hi] pair list. The fast paths in
/// [runeWidth] (cp < 0x300, astral) keep most content out of here entirely;
/// the remainder is short ranges first, so the scan is cheap for chat text.
bool _inRanges(int cp, List<int> ranges) {
  for (var i = 0; i < ranges.length; i += 2) {
    if (cp >= ranges[i] && cp <= ranges[i + 1]) return true;
    if (cp < ranges[i]) return false; // sorted — nothing later can match
  }
  return false;
}
