/// Interval-grammar helper for `set_timer` (§5 of docs/proposals/timer_system.md).
///
/// Grammar:
/// ```
/// every   := pair+
/// pair    := ws* integer ws* unit ws*
/// unit    := 's' | 'm' | 'h' | 'd'   (case-insensitive)
/// integer := [0-9]{1,6}              (no zero components)
/// ```
/// Compound sums are allowed in any order (`90s`, `5m`, `1h30m`, `30m1h`).
/// Rejected: empty, bare number, bare unit, words, zero components, signs or
/// other punctuation, more than 6 digits per component.
library;

import 'timer_service.dart' show kMaxTimerInterval, kMinTimerInterval;

/// The outcome of parsing an `every` string (§5).
class ParsedInterval {
  /// Sum of the components, clamped into
  /// [`kMinTimerInterval`, `kMaxTimerInterval`] after summing.
  final Duration duration;

  /// True when the sum fell outside the clamp window and was pulled in
  /// (clamping is not an error — §5).
  final bool clamped;

  /// The unclamped sum in seconds (the grammar's unit), for diagnostics.
  final int totalSeconds;

  const ParsedInterval({
    required this.duration,
    required this.clamped,
    required this.totalSeconds,
  });
}

bool _isDigit(String ch) =>
    ch == '0' || ch == '1' || ch == '2' || ch == '3' || ch == '4' ||
    ch == '5' || ch == '6' || ch == '7' || ch == '8' || ch == '9';

int? _unitSeconds(String ch) {
  switch (ch) {
    case 's':
    case 'S':
      return 1;
    case 'm':
    case 'M':
      return 60;
    case 'h':
    case 'H':
      return 3600;
    case 'd':
    case 'D':
      return 86400;
  }
  return null;
}

/// Parses an `every` string per the §5 grammar. Returns null when [input]
/// does not parse; use [describeIntervalGrammar] for the rejection text.
ParsedInterval? parseInterval(String input) {
  var totalSeconds = 0;
  var i = 0;
  final n = input.length;
  var anyPair = false;

  void skipWhitespace() {
    while (i < n && (input.codeUnitAt(i) == 0x20 || input.codeUnitAt(i) == 0x09)) {
      i++;
    }
  }

  while (i < n) {
    skipWhitespace();
    if (i >= n) break;

    // integer: [0-9]{1,6}. A run longer than 6 digits is a rejection, not a
    // partial parse.
    final digitsStart = i;
    while (i < n && _isDigit(input[i])) {
      i++;
    }
    final digitCount = i - digitsStart;
    if (digitCount == 0 || digitCount > 6) return null;

    final value = int.parse(input.substring(digitsStart, i));
    if (value == 0) return null; // no zero components

    skipWhitespace();

    // unit: s/m/h/d, case-insensitive.
    if (i >= n) return null; // bare number
    final unitSeconds = _unitSeconds(input[i]);
    if (unitSeconds == null) return null;
    i++;

    totalSeconds += value * unitSeconds;
    anyPair = true;
  }
  if (!anyPair) return null; // empty (or whitespace-only)

  final unclamped = Duration(seconds: totalSeconds);
  var duration = unclamped;
  var clamped = false;
  if (unclamped < kMinTimerInterval) {
    duration = kMinTimerInterval;
    clamped = true;
  } else if (unclamped > kMaxTimerInterval) {
    duration = kMaxTimerInterval;
    clamped = true;
  }
  return ParsedInterval(
    duration: duration,
    clamped: clamped,
    totalSeconds: totalSeconds,
  );
}

/// The grammar, for the `set_timer` rejection text (§6.1: "tool error stating
/// the grammar").
const String describeIntervalGrammar =
    'every must be one or more <number><unit> pairs with units '
    's/m/h/d (case-insensitive), 1-6 digits, no zero components, '
    "e.g. '90s', '5m', '1h30m'";
