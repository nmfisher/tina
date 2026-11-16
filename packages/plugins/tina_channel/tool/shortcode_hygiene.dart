// Lists shortcode.dart's word lists and reports hygiene problems:
// duplicates within a list, cross-list duplicates, non a-z characters,
// words that are prefixes of other words (ambiguity), and counts.
import '../lib/src/shortcode.dart';

void main() {
  final problems = <String>[];
  void check(String label, List<String> words) {
    if (words.length != words.toSet().length) {
      final seen = <String>[];
      for (final w in words) {
        if (words.where((x) => x == w).length > 1 && !seen.contains(w)) {
          seen.add(w);
        }
      }
      problems.add('$label duplicates: $seen');
    }
    for (final w in words) {
      if (!RegExp(r'^[a-z]+$').hasMatch(w)) {
        problems.add('$label non-ascii-letter: "$w"');
      }
      if (w.length < 4) problems.add('$label too short: "$w"');
    }
  }

  check('adjectives', shortcodeAdjectives);
  check('nouns', shortcodeNouns);

  final cross = shortcodeAdjectives.toSet().intersection(shortcodeNouns.toSet());
  if (cross.isNotEmpty) problems.add('cross-list duplicates: $cross');

  final all = [...shortcodeAdjectives, ...shortcodeNouns];
  for (final a in all) {
    for (final b in all) {
      if (a != b && b.startsWith('$a')) {
        problems.add('prefix pair: "$a" / "$b"');
      }
    }
  }

  print('adjectives: ${shortcodeAdjectives.length}');
  print('nouns: ${shortcodeNouns.length}');
  print('combinations: ${shortcodeAdjectives.length * shortcodeNouns.length}');
  if (problems.isEmpty) {
    print('hygiene: CLEAN');
  } else {
    print('hygiene problems (${problems.length}):');
    for (final p in problems.toSet()) print('  - $p');
  }
}
