import 'fuzzy.dart';
import 'symbol_table.dart';

/// Extract seed node IDs from a natural language query via string matching.
List<String> seedQuery(
  SymbolTable symbols,
  String query, {
  int maxResults = 10,
}) {
  if (query.isEmpty) return const [];
  final lower = query.toLowerCase();

  final scored = <String, int>{};

  for (final qName in symbols.qualifiedNames) {
    final sym = symbols[qName]!;
    var score = 0;

    // Exact name match (highest priority).
    if (sym.name.toLowerCase() == lower) {
      score = 1000;
    }
    // Name starts with query.
    else if (sym.name.toLowerCase().startsWith(lower)) {
      score = 500;
    }
    // Query is a camelCase fragment.
    else if (_camelParts(sym.name).any((p) => p.toLowerCase().startsWith(lower))) {
      score = 300;
    }
    // Query is contained in name.
    else if (sym.name.toLowerCase().contains(lower)) {
      score = 200;
    }
    // Qualified name contains query.
    else if (qName.toLowerCase().contains(lower)) {
      score = 100;
    }

    if (score > 0) {
      // Tiebreak: shorter qualified names are more specific.
      scored[qName] = score - qName.length;
    }
  }

  // Also try fuzzy matching on symbol names.
  if (scored.length < maxResults) {
    final names = symbols.qualifiedNames.toList();
    final fuzzyMatches = rankFuzzy(lower, names);
    for (final match in fuzzyMatches) {
      scored.putIfAbsent(match, () => 50 - match.length);
    }
  }

  // Sort by score descending, then keep only the best-scoring bearer of
  // each bare symbol name. Without this, N classes declaring the same
  // member (e.g. streamIdleTimeout on Config and six providers) take N
  // of the maxResults slots and crowd out weaker-but-different matches
  // (ProviderStreamConsumer fell out of the top 10 entirely) — and a
  // seed list's whole job is diverse context anchors (#39).
  final sorted = scored.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final seenNames = <String>{};
  final unique = sorted
      .where((e) => seenNames.add(e.key.split('.').last))
      .toList();

  return unique.take(maxResults).map((e) => e.key).toList();
}

List<String> _camelParts(String name) {
  final parts = <String>[];
  var start = 0;
  for (var i = 1; i < name.length; i++) {
    final c = name.codeUnitAt(i);
    if (c >= 0x41 && c <= 0x5A) {
      parts.add(name.substring(start, i));
      start = i;
    }
  }
  parts.add(name.substring(start));
  return parts;
}
