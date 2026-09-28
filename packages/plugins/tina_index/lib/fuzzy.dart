/// Subsequence-fuzzy match. The query characters must appear in the
/// candidate in order, but not necessarily contiguously.
int? fuzzyScore(String query, String candidate) {
  if (query.isEmpty) return 0;
  if (candidate.isEmpty) return null;

  final q = query.toLowerCase();
  final c = candidate.toLowerCase();

  var qi = 0;
  var score = 0;
  var lastMatch = -2;
  var run = 0;

  for (var ci = 0; ci < c.length && qi < q.length; ci++) {
    if (c.codeUnitAt(ci) != q.codeUnitAt(qi)) {
      run = 0;
      continue;
    }
    var bonus = 1;
    if (ci == lastMatch + 1) {
      run++;
      bonus += run * 3;
    } else {
      run = 0;
    }
    if (_isBoundary(candidate, ci)) bonus += 10;
    if (candidate.codeUnitAt(ci) == query.codeUnitAt(qi)) bonus += 2;
    score += bonus;
    lastMatch = ci;
    qi++;
  }

  if (qi < q.length) return null;
  score -= candidate.length - query.length;
  return score;
}

bool _isBoundary(String s, int i) {
  if (i == 0) return true;
  final prev = s.codeUnitAt(i - 1);
  if (prev == 0x2F || prev == 0x5C) return true;
  if (prev == 0x2E) return true;
  if (prev == 0x5F || prev == 0x2D) return true;
  if (prev == 0x20) return true;
  if (prev >= 0x61 && prev <= 0x7A) {
    final cur = s.codeUnitAt(i);
    if (cur >= 0x41 && cur <= 0x5A) return true;
  }
  return false;
}

/// Rank [candidates] against [query] using [fuzzyScore]. Returns matches
/// sorted best-first.
List<String> rankFuzzy(String query, Iterable<String> candidates) {
  if (query.isEmpty) return candidates.toList();
  final scored = <MapEntry<String, int>>[];
  for (final c in candidates) {
    final s = fuzzyScore(query, c);
    if (s != null) scored.add(MapEntry(c, s));
  }
  scored.sort((a, b) => b.value.compareTo(a.value));
  return [for (final e in scored) e.key];
}
