/// Split [text] into chunks where each has at most [maxCols] visible
/// columns. ANSI escape sequences are preserved but don't count toward
/// the column budget.
List<String> wrapAnsiAware(String text, int maxCols) {
  if (maxCols <= 0) return [text];
  final chunks = <String>[];
  var start = 0;
  var visible = 0;
  var i = 0;
  while (i < text.length) {
    if (text[i] == '\x1b') {
      i++;
      if (i < text.length && text[i] == '[') {
        i++;
        while (i < text.length && !_isCsiFinal(text[i])) {
          i++;
        }
        if (i < text.length) i++;
      } else if (i < text.length) {
        i++;
      }
      continue;
    }
    visible++;
    if (visible > maxCols) {
      chunks.add(text.substring(start, i));
      start = i;
      visible = 1;
    }
    i++;
  }
  if (start < text.length) {
    chunks.add(text.substring(start));
  }
  return chunks.isEmpty ? [text] : chunks;
}

/// Returns true if [s] contains at least one printable character (not an
/// escape sequence and not a C0 control character).
bool hasPrintableContent(String s) {
  var i = 0;
  while (i < s.length) {
    if (s[i] == '\x1b') {
      i++;
      if (i < s.length && s[i] == '[') {
        i++;
        while (i < s.length && !_isCsiFinal(s[i])) {
          i++;
        }
        if (i < s.length) i++;
      } else if (i < s.length) {
        i++;
      }
      continue;
    }
    if (s.codeUnitAt(i) >= 0x20) return true;
    i++;
  }
  return false;
}

bool _isCsiFinal(String ch) {
  final c = ch.codeUnitAt(0);
  return c >= 0x40 && c <= 0x7E;
}
