/// Quote-aware word parsing for `!`-mode (shell passthrough) input lines.
///
/// The console routes a submitted line to the shell plugin when the first
/// non-whitespace character is `!` (the host trims, then matches the `!`
/// input prefix — see `Commands.matchPrefix`). [isBangLine] mirrors that
/// predicate so completion triggers on exactly the lines that submit as
/// shell commands: `!cmd`, `  !cmd` and `!!cmd` are in, `text !` is not.
///
/// The parser is deliberately small and editor-free: it splits a line into
/// words the way a POSIX shell would for word-splitting purposes (single and
/// double quotes group, quotes are retained in the raw word text), and it
/// identifies the word a completion request applies to. Backslash escaping
/// and tilde expansion are out of scope — a backslash is an ordinary
/// character and `~` is passed through literally.
library;

import 'package:fuzzy_ranker/fuzzy_ranker.dart';

/// One shell-like word of a `!`-mode line.
///
/// [text] is the raw slice [start, end) of the line, including any quote
/// characters; [quote] names the quote character the word opened with, if
/// any. A word opened with a quote and never closed runs to the end of the
/// line (or the cursor).
final class BangWord {
  /// Index of the first character of the word in the full line.
  final int start;

  /// One past the last character of the word in the full line.
  final int end;

  /// The raw line slice [start, end), quotes included.
  final String text;

  /// `"'`, `'"'` when the word opens with a quote, otherwise null.
  final String? quote;

  /// Whether the word's closing quote was seen before [end]. Always true
  /// for unquoted words.
  final bool closed;

  const BangWord({
    required this.start,
    required this.end,
    required this.text,
    required this.quote,
    required this.closed,
  });

  /// The completion query for this word: the raw text minus a leading quote
  /// and, when present, its matching trailing close.
  String get query {
    final q = quote;
    var t = text;
    if (q != null && t.startsWith(q)) {
      t = t.substring(1);
      if (closed && t.endsWith(q) && t.length >= 1) {
        t = t.length == 1 ? '' : t.substring(0, t.length - 1);
      }
    }
    return t;
  }
}

/// Index of the `!` that makes a line shell passthrough input, or -1.
///
/// Matches the host's submit routing: the first non-blank character must be
/// `!`. Whitespace means space or tab, like `String.trim`.
int bangIndex(String line) {
  for (var i = 0; i < line.length; i++) {
    final c = line.codeUnitAt(i);
    if (c == 0x20 || c == 0x09) continue;
    return c == 0x21 ? i : -1;
  }
  return -1;
}

/// Whether the line submits as a shell command (`!` passthrough).
bool isBangLine(String line) => bangIndex(line) >= 0;

/// Splits the words after the `!` of a `!`-mode line, quote-aware.
///
/// Returns an empty list for a line without a leading `!`. Words are in
/// line order; the `!` itself is not part of any word.
List<BangWord> bangWords(String line) {
  final bang = bangIndex(line);
  if (bang < 0) return const [];
  return _words(line, bang + 1, line.length);
}

/// The word a Tab completion at [cursor] applies to, plus whether it is the
/// command word (the first word after the `!`).
///
/// The completion word is the text from just after the last unquoted
/// whitespace before [cursor] up to [cursor] itself — completing up to the
/// cursor, the way readline does. A cursor sitting right after a space (or
/// right after the `!`) yields an empty word anchored there, so Tab offers
/// candidates for a not-yet-typed word. Null when [cursor] is at or before
/// the `!` (nothing after the bang to complete) or the line is not in
/// `!` mode.
({BangWord word, bool isCommandWord})? bangWordAtCursor(
    String line, int cursor) {
  final bang = bangIndex(line);
  if (bang < 0 || cursor <= bang) return null;
  final start = _lastWordStart(line, bang + 1, cursor);
  final text = line.substring(start, cursor);
  final quote = _quoteAt(line, start, cursor);
  return (
    word: BangWord(
      start: start,
      end: cursor,
      text: text,
      quote: quote,
      closed: _isClosed(line, start, cursor),
    ),
    isCommandWord: start == bang + 1,
  );
}

// -- Internals ------------------------------------------------------------

List<BangWord> _words(String line, int from, int to) {
  final out = <BangWord>[];
  var i = from;
  while (i < to) {
    final c = line.codeUnitAt(i);
    if (c == 0x20 || c == 0x09) {
      i++;
      continue;
    }
    final start = i;
    String? quote;
    var closed = true;
    if (c == 0x27 || c == 0x22) {
      quote = String.fromCharCode(c);
      i++;
      while (i < to && line.codeUnitAt(i) != c) {
        i++;
      }
      if (i < to) {
        i++; // consume the close
      } else {
        closed = false;
      }
      // A quoted segment glues to any immediately following text:
      // `'a'b c` is the single word `'a'b`.
      while (i < to) {
        final d = line.codeUnitAt(i);
        if (d == 0x20 || d == 0x09) break;
        i++;
      }
    } else {
      while (i < to) {
        final d = line.codeUnitAt(i);
        if (d == 0x20 || d == 0x09) break;
        i++;
      }
    }
    out.add(BangWord(
      start: start,
      end: i,
      text: line.substring(start, i),
      quote: quote,
      closed: closed,
    ));
  }
  return out;
}

/// Position of the completion word starting at or before [cursor]: the
/// character after the last unquoted whitespace in [from, cursor), where
/// quote state is tracked forward from the start of the bang line — a
/// backward scan cannot tell that a space sits inside an opening quote.
int _lastWordStart(String line, int from, int cursor) {
  var start = from;
  String? inQuote;
  for (var i = from; i < cursor; i++) {
    final c = line.codeUnitAt(i);
    if (inQuote != null) {
      if (c == inQuote.codeUnitAt(0)) inQuote = null;
      continue;
    }
    if (c == 0x27 || c == 0x22) {
      inQuote = String.fromCharCode(c);
    } else if (c == 0x20 || c == 0x09) {
      start = i + 1;
    }
  }
  return start;
}

/// The quote character the completion word opens with, if any.
String? _quoteAt(String line, int start, int cursor) {
  if (start >= cursor) return null;
  final c = line.codeUnitAt(start);
  return (c == 0x27 || c == 0x22) ? String.fromCharCode(c) : null;
}

/// Whether the quote opened at [start] is closed before [cursor].
bool _isClosed(String line, int start, int cursor) {
  final q = _quoteAt(line, start, cursor);
  if (q == null) return true;
  final c = q.codeUnitAt(0);
  for (var i = start + 1; i < cursor; i++) {
    if (line.codeUnitAt(i) == c) return true;
  }
  return false;
}

/// The pair of `!`-mode completion sources: [commands] completes the first
/// word (command names), [paths] completes later words (file paths). A null
/// [BangCompletion] (the wasm compilation) leaves Tab inert in `!` mode.
final class BangCompletion {
  /// Completes the command word: executable names from a PATH scan plus a
  /// curated list of common shell commands.
  final CompletionProvider commands;

  /// Completes argument words: file paths, reusing the `@` file machinery.
  final CompletionProvider paths;

  const BangCompletion({required this.commands, required this.paths});
}
