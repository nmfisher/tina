// Parsed SGR runs and a bounded parse cache.
//
// `_emitSgrStyled` (notcurses_backend.dart) re-scans and re-parses the same
// styled string on every repaint, and emits every SGR-derived setter call
// unconditionally. This module gives each distinct styled string an immutable
// parsed representation — a list of [StyledRun]s — computed once and cached.
//
// Two adjacent runs that resolve to the same terminal state (same fg/bg/style
// bits) are collapsed during parsing, so a string like `\x1b[32mAB\x1b[32mCD`
// yields a single run ("ABCD" under one green) instead of two. The emitter then
// issues one setter group + one putStr for the joined text, dropping the
// redundant mid-string setter. A trailing reset (`\x1b[0m`) is preserved
// exactly, so byte output is identical to the pre-Phase-4 emitter for every
// non-collapsible input (see test/styled_runs_test.dart parity cases).
//
// The per-code SGR logic lives in one place — [applySgrCode] — shared by both
// the live emitter (via [_applySgr]) and [parseStyledRuns], so the two can't
// drift.

import 'dart:collection';

import 'package:meta/meta.dart';

import 'package:dart_notcurses/dart_notcurses.dart' as nc;

import 'input_latency.dart';

/// Bump this whenever [applySgrCode]'s semantics change so stale cached runs
/// (computed against the old rules) are never reused.
const int kStyledRunParserVersion = 1;

/// Global theme-style version, incremented by [Screen.setTheme]. Folded into
/// the cache key so a theme change can never reuse a cached run whose colors
/// were resolved against the prior theme.
int gThemeStyleVersion = 0;

/// Increment [gThemeStyleVersion]. Called by [Screen.setTheme].
void bumpThemeStyleVersion() => gThemeStyleVersion++;

/// The terminal state established before a run of plain text. `fg`/`bg` null =
/// terminal default; `stylebits` is the OR'd NCSTYLE_* mask (0 = no style
/// bits). Equality over (fg, bg, stylebits) is the adjacency key for collapsing
/// runs.
@immutable
class TextStyleState {
  final int? fg;
  final int? bg;
  final int stylebits;

  const TextStyleState(this.fg, this.bg, this.stylebits);

  @override
  bool operator ==(Object other) =>
      other is TextStyleState &&
      other.fg == fg &&
      other.bg == bg &&
      other.stylebits == stylebits;

  @override
  int get hashCode => Object.hash(fg, bg, stylebits);
}

/// A run of plain text preceded by the style that applies to it.
@immutable
class StyledRun {
  final TextStyleState style;
  final String text;

  /// The sink calls to emit (in order) before [text] to establish [style].
  /// Captured from the SGR sequence that opened this run; empty for a run that
  /// begins at the default baseline (no preceding SGR).
  final List<StyledStyleFn> establishCalls;

  const StyledRun(this.style, this.text, this.establishCalls);
}

/// The minimal run span that must be re-emitted to turn one painted styled row
/// into another. Returned by [diffStyledRuns].
///
/// A partial write always starts from the default baseline (the emitter resets
/// to default before emitting [runs]), so it can never inherit a prior region's
/// leftover style — only the unchanged prefix is left on screen untouched.
@immutable
class StyledRunSpan {
  /// Index into the new run list of the first run that differs from the old
  /// row. Everything before this index is unchanged and left untouched.
  final int startIndex;

  /// The new runs from [startIndex] onward, which must be emitted in order to
  /// repaint the changed tail of the row.
  final List<StyledRun> runs;

  /// Display-column offset of the first changed run within the row — the sum of
  /// the unchanged prefix runs' visible widths. The partial write starts here.
  final int colOffset;

  const StyledRunSpan(this.startIndex, this.runs, this.colOffset);
}

/// The style-setter slice of the notcurses sink, factored out so the shared SGR
/// state machine can drive either a live [_SgrSink] or a recording fake.
abstract class StyledStyleSink {
  void setStyles(int stylebits);
  void setFgRGB(int hex);
  void setBgRGB(int hex);
  void setFgDefault();
  void setBgDefault();
}

/// A function that applies one style setter to a [StyledStyleSink].
typedef StyledStyleFn = void Function(StyledStyleSink sink);

/// xterm-ish RGB values for the 8 basic ANSI colors. SGR 30-37 / 40-47 index
/// into this; the plane-styling API is truecolor-only, so we map at the parser
/// layer. (Single source of truth; the live emitter maps through here too.)
const List<int> _basicColorRgb = [
  0x000000,
  0xcd0000,
  0x00cd00,
  0xcdcd00,
  0x0000ee,
  0xcd00cd,
  0x00cdcd,
  0xe5e5e5,
];

/// xterm-ish RGB values for the 8 bright ANSI colors (SGR 90-97 / 100-107).
const List<int> _brightColorRgb = [
  0x7f7f7f,
  0xff0000,
  0x00ff00,
  0xffff00,
  0x5c5cff,
  0xff00ff,
  0x00ffff,
  0xffffff,
];

/// Mutable cumulative SGR state. Tracks the terminal's fg/bg/style bits as a
/// string is parsed so runs can be collapsed when an SGR sequence leaves the
/// state unchanged.
class SgrState {
  int stylebits = 0;
  int? fg;
  int? bg;

  /// True once any style-affecting code (0, 1, 3, 4, 22, 23, 24) has been
  /// seen in the current SGR sequence. Mirrors the original `styleAccum !=
  /// null` gate that decides whether a trailing `setStyles` is emitted.
  bool styleTouched = false;

  void reset() {
    stylebits = 0;
    fg = null;
    bg = null;
    styleTouched = true;
  }

  TextStyleState snapshot() => TextStyleState(fg, bg, stylebits);

  bool sameState(SgrState o) =>
      stylebits == o.stylebits && fg == o.fg && bg == o.bg;
}

/// Apply one SGR sequence's parameters, emitting setters to [sink] AND updating
/// the cumulative state [acc]. Shared by the live emitter and the parser so the
/// two never diverge. Empty [params] is treated as `0` (full reset).
void applySgrCode(List<String> parts, StyledStyleSink sink, SgrState acc) {
  var idx = 0;
  while (idx < parts.length) {
    final code = int.tryParse(parts[idx]) ?? 0;
    switch (code) {
      case 0:
        acc.reset();
        sink.setFgDefault();
        sink.setBgDefault();
        break;
      case 1:
        acc.stylebits |= nc.Style.bold;
        acc.styleTouched = true;
        break;
      case 2:
        // ANSI "faint" — notcurses has no matching style bit; approximate with
        // a muted mid-grey fg. Any later fg change supersedes it.
        acc.fg = 0x808080;
        sink.setFgRGB(0x808080);
        break;
      case 3:
        acc.stylebits |= nc.Style.italic;
        acc.styleTouched = true;
        break;
      case 4:
        acc.stylebits |= nc.Style.underline;
        acc.styleTouched = true;
        break;
      case 22:
      case 23:
      case 24:
        // Coarse turn-off; fine tracking would need a shadow of current bits.
        acc.stylebits = 0;
        acc.styleTouched = true;
        break;
      case 38:
        idx += _consumeExtendedRgb(parts, idx, (rgb) {
          acc.fg = rgb;
          sink.setFgRGB(rgb);
        });
        break;
      case 39:
        acc.fg = null;
        sink.setFgDefault();
        break;
      case 48:
        idx += _consumeExtendedRgb(parts, idx, (rgb) {
          acc.bg = rgb;
          sink.setBgRGB(rgb);
        });
        break;
      case 49:
        acc.bg = null;
        sink.setBgDefault();
        break;
      default:
        if (code >= 30 && code <= 37) {
          acc.fg = _basicColorRgb[code - 30];
          sink.setFgRGB(_basicColorRgb[code - 30]);
        } else if (code >= 40 && code <= 47) {
          acc.bg = _basicColorRgb[code - 40];
          sink.setBgRGB(_basicColorRgb[code - 40]);
        } else if (code >= 90 && code <= 97) {
          acc.fg = _brightColorRgb[code - 90];
          sink.setFgRGB(_brightColorRgb[code - 90]);
        } else if (code >= 100 && code <= 107) {
          acc.bg = _brightColorRgb[code - 100];
          sink.setBgRGB(_brightColorRgb[code - 100]);
        }
      // Unknown codes are skipped silently.
    }
    idx++;
  }
  if (acc.styleTouched) sink.setStyles(acc.stylebits);
}

/// Consume the sub-parameters of an extended SGR (`38`/`48`). Only the
/// `;2;r;g;b` (truecolor) form is applied; `;5;n` (256-palette) is eaten but
/// not translated. Returns the number of extra parts consumed beyond the
/// `38`/`48` head so the caller advances by that plus its own `idx++`.
int _consumeExtendedRgb(
    List<String> parts, int idx, void Function(int) setRgb) {
  if (idx + 1 >= parts.length) return 0;
  final mode = int.tryParse(parts[idx + 1]) ?? -1;
  if (mode == 2 && idx + 4 < parts.length) {
    final r = int.tryParse(parts[idx + 2]) ?? 0;
    final g = int.tryParse(parts[idx + 3]) ?? 0;
    final b = int.tryParse(parts[idx + 4]) ?? 0;
    setRgb((r << 16) | (g << 8) | b);
    return 4;
  }
  if (mode == 5 && idx + 2 < parts.length) {
    return 2;
  }
  return 0;
}

/// True if [text] contains any ESC byte (hence any SGR to parse). Plain strings
/// bypass the cache entirely.
bool _hasEsc(String text) {
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x1b) return true;
  }
  return false;
}

/// A [StyledStyleSink] that records each setter call as a [StyledStyleFn] into
/// a list supplied at construction.
class _RecordingSink implements StyledStyleSink {
  final List<StyledStyleFn> calls;
  _RecordingSink(this.calls);

  @override
  void setStyles(int stylebits) {
    calls.add((s) => s.setStyles(stylebits));
  }

  @override
  void setFgRGB(int hex) {
    calls.add((s) => s.setFgRGB(hex));
  }

  @override
  void setBgRGB(int hex) {
    calls.add((s) => s.setBgRGB(hex));
  }

  @override
  void setFgDefault() {
    calls.add((s) => s.setFgDefault());
  }

  @override
  void setBgDefault() {
    calls.add((s) => s.setBgDefault());
  }
}

/// Intermediate run emitted at each CSI boundary during the parse walk, before
/// adjacent same-state runs are collapsed.
class _RawRun {
  final TextStyleState style;
  final String text;
  final List<StyledStyleFn> calls;
  _RawRun(this.style, this.text, this.calls);
}

/// Parse [text] into collapsed runs. Adjacent runs that resolve to the same
/// terminal state are merged (their text concatenated, the redundant intervening
/// establish-calls dropped) — EXCEPT a trailing run with empty text, which is
/// always preserved so a trailing reset (`\x1b[0m`) establishes the baseline
/// for subsequent output exactly as the pre-Phase-4 emitter did. A plain string
/// yields a single default-baseline run with no establish-calls.
List<StyledRun> parseStyledRuns(String text) {
  if (!_hasEsc(text)) {
    return [StyledRun(const TextStyleState(null, null, 0), text, const [])];
  }

  // Phase 1: walk CSI boundaries, emitting one raw run per boundary.
  final raw = <_RawRun>[];
  final acc = SgrState();
  // establishCalls for the text currently being buffered (the style under which
  // buf is rendered).
  List<StyledStyleFn> openCalls = const [];
  final buf = StringBuffer();

  var i = 0;
  while (i < text.length) {
    final cu = text.codeUnitAt(i);
    if (cu == 0x1b &&
        i + 1 < text.length &&
        text.codeUnitAt(i + 1) == 0x5b) {
      raw.add(_RawRun(acc.snapshot(), buf.toString(), openCalls));
      buf.clear();
      openCalls = const [];

      var j = i + 2;
      while (j < text.length) {
        final c = text.codeUnitAt(j);
        if (c >= 0x40 && c <= 0x7e) break;
        j++;
      }
      if (j >= text.length) {
        // Malformed trailing escape — drop the rest (matches _emitSgrStyled).
        break;
      }
      if (text.codeUnitAt(j) == 0x6d /* 'm' */) {
        final calls = <StyledStyleFn>[];
        applySgrCode(
          text.substring(i + 2, j).isEmpty
              ? const ['0']
              : text.substring(i + 2, j).split(';'),
          _RecordingSink(calls),
          acc,
        );
        openCalls = calls;
      }
      // Non-SGR CSI (cursor movement, etc.) is dropped silently; state is
      // unchanged so the following text continues under the prior style.
      i = j + 1;
    } else {
      buf.writeCharCode(cu);
      i++;
    }
  }
  raw.add(_RawRun(acc.snapshot(), buf.toString(), openCalls));

  return _collapse(raw);
}

/// Compare two parsed styled rows and return the minimal run span that must be
/// re-emitted (the changed tail, from the first differing run through the end)
/// to turn [oldRuns] into [newRuns]. Returns null when the rows are identical
/// (caller skips the row entirely).
///
/// Only the changed tail is returned rather than a common-prefix +
/// common-suffix window: a styled run's cells each carry an absolute style, and
/// a partial write must establish a known default baseline at its start (the
/// documented boundary invariant). Re-emitting only a middle span would require
/// knowing the sink state the unchanged prefix left active — which the emitter
/// must never assume. So the unchanged prefix is left on screen untouched and
/// the whole tail from the first changed run is cleared + rewritten run-by-run
/// from a clean baseline. [StyledRunSpan.colOffset] is the display-column offset
/// of the first changed run (the unchanged prefix runs' visible widths).
StyledRunSpan? diffStyledRuns(
  List<StyledRun> oldRuns,
  List<StyledRun> newRuns,
) {
  final minLen =
      oldRuns.length < newRuns.length ? oldRuns.length : newRuns.length;
  var i = 0;
  while (i < minLen &&
      _runsEqual(oldRuns[i], newRuns[i])) {
    i++;
  }
  // Identical (same runs and same length) → nothing to emit.
  if (i == oldRuns.length && i == newRuns.length) return null;

  // Column offset of the first changed run = sum of the unchanged prefix
  // runs' visible widths. run.text is plain (no SGR), so each code unit is a
  // cell — matching _displayWidth for plain text.
  var colOffset = 0;
  for (var p = 0; p < i; p++) {
    colOffset += newRuns[p].text.length;
  }
  return StyledRunSpan(i, newRuns.sublist(i), colOffset);
}

/// True when two runs would paint identical cells: same resolved style and same
/// plain text. establishCalls may differ (different SGR grammar, same effect) —
/// only the rendered result matters for diffing.
bool _runsEqual(StyledRun a, StyledRun b) =>
    a.style == b.style && a.text == b.text;

/// Render [runs] to a self-contained SGR string: each run establishes its
/// *complete* style from the default baseline (a leading reset, then its
/// fg/bg/stylebits) before its text. The result is safe to emit as a *partial*
/// row repaint after a leading `\x1b[0m`, because no run relies on style left
/// active by a prior run — every run is independent.
///
/// This is what makes a partial styled re-emit correct: a run's
/// [StyledRun.establishCalls] are relative to the *cumulative* state the parser
/// had reached (e.g. a red run opened after `\x1b[1m` only records
/// `setFgRGB(red)`, expecting bold to persist). Replaying those mid-row from a
/// clean baseline would drop the bold. So we regenerate each run's full SGR from
/// its resolved [TextStyleState] instead. The trailing reset run (empty text,
/// default style) is emitted as a bare `\x1b[0m` so the row ends on the default
/// baseline.
String renderStyledRuns(List<StyledRun> runs) {
  final sb = StringBuffer();
  for (final run in runs) {
    final style = run.style;
    // Default run (the trailing reset): a bare reset, no text.
    if (style.fg == null && style.bg == null && style.stylebits == 0) {
      sb.write('\x1b[0m');
      sb.write(run.text);
      continue;
    }
    sb.write('\x1b[0m');
    // Style bits → SGR codes. applySgrCode only ever sets bold/italic/underline
    // (1/3/4); struck/undercurl have no standard SGR code and are never set, so
    // they're omitted here.
    final bits = <String>[];
    if (style.stylebits & nc.Style.bold != 0) bits.add('1');
    if (style.stylebits & nc.Style.italic != 0) bits.add('3');
    if (style.stylebits & nc.Style.underline != 0) bits.add('4');
    if (bits.isNotEmpty) sb.write('\x1b[${bits.join(';')}m');
    if (style.fg != null) {
      final rgb = style.fg!;
      sb.write('\x1b[38;2;${(rgb >> 16) & 0xff};${(rgb >> 8) & 0xff};${rgb & 0xff}m');
    }
    if (style.bg != null) {
      final rgb = style.bg!;
      sb.write('\x1b[48;2;${(rgb >> 16) & 0xff};${(rgb >> 8) & 0xff};${rgb & 0xff}m');
    }
    sb.write(run.text);
  }
  return sb.toString();
}

/// Collapse adjacent raw runs that share the same terminal state, concatenating
/// their text and dropping the redundant intervening establish-calls. The final
/// run is preserved as-is when it carries empty text (a trailing reset must
/// establish the baseline for what follows, matching the pre-Phase-4 emitter).
/// Runs that carry neither text nor establish-calls emit nothing and are
/// dropped (e.g. the empty baseline run before a leading SGR).
List<StyledRun> _collapse(List<_RawRun> raw) {
  if (raw.isEmpty) return const [];
  final lastIndex = raw.length - 1;
  final out = <_RawRun>[];
  for (var i = 0; i < raw.length; i++) {
    final r = raw[i];
    if (out.isEmpty) {
      out.add(r);
      continue;
    }
    final prev = out.last;
    final isTrailingEmpty = i == lastIndex && r.text.isEmpty;
    if (!isTrailingEmpty && r.style == prev.style) {
      // Same state: merge text into the previous run, drop redundant calls.
      out[out.length - 1] =
          _RawRun(prev.style, prev.text + r.text, prev.calls);
    } else {
      out.add(r);
    }
  }
  return [
    for (final r in out)
      if (r.text.isNotEmpty || r.calls.isNotEmpty)
        StyledRun(r.style, r.text, r.calls),
  ];
}

/// Bounded cache of parsed styled-run lists. Plain strings (no ESC) bypass
/// entirely. Keyed by `${text}|${kStyledRunParserVersion}|${gThemeStyleVersion}`
/// and bounded by entry count (256) and cacheable input length (4 KiB) — longer
/// inputs are parsed uncached so a pathological line can't evict the working
/// set.
class StyledRunCache {
  static const int maxEntries = 256;
  static const int maxInputBytes = 4096;

  final Map<String, List<StyledRun>> _map = LinkedHashMap();

  /// Returns the cached runs for [text], parsing+inserting on a miss. Returns
  /// null for plain strings (no ESC) — the caller uses its plain fast path.
  List<StyledRun>? get(String text) {
    if (!_hasEsc(text)) return null;
    if (text.length > maxInputBytes) {
      OpCounters.instance.styleParseMisses++;
      return parseStyledRuns(text);
    }
    final key = '$text|$kStyledRunParserVersion|$gThemeStyleVersion';
    final hit = _map[key];
    if (hit != null) {
      OpCounters.instance.styleParseHits++;
      return hit;
    }
    OpCounters.instance.styleParseMisses++;
    final runs = parseStyledRuns(text);
    _map[key] = runs;
    if (_map.length > maxEntries) {
      _map.remove(_map.keys.first);
    }
    return runs;
  }

  /// Drop all entries. Called on theme change and backend swap.
  void clear() => _map.clear();

  /// Number of entries currently cached (test/introspection hook).
  int get length => _map.length;
}

/// Process-wide parse cache.
final StyledRunCache styledRunCache = StyledRunCache();
