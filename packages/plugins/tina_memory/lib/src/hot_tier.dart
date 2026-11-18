import '../memory_store_api.dart';

/// The session-start hot tier's byte cap (named constant, issue 94):
/// the rendered block stays under this, newest/hottest entries kept
/// whole, overflow cut between entries (never mid-entry).
const int hotTierByteCap = 3072;

/// How many entries the tier considers before capping.
const int hotTierEntryLimit = 50;

/// Renders the session-start memory block: the hottest entries
/// (recall recency + count, both tiers) under [hotTierByteCap], as a
/// labeled prompt section — ids, categories, ages, and the staleness
/// caveat. Null when there is nothing to inject (silence, not an
/// empty block).
String? hotTierBlock(MemoryStorePair pair) {
  final hottest = pair.hottest(limit: hotTierEntryLimit);
  if (hottest.isEmpty) return null;

  final age = (DateTime entry) {
    final days =
        DateTime.now().difference(entry).inDays;
    return days == 0 ? 'today' : days == 1 ? '1d' : '${days}d';
  };

  String render(MemoryEntry e) =>
      '#${e.id} (${e.scope.name}/${e.category.name}, '
      'updated ${age(e.updatedAt)}): ${e.text}';

  // Keep whole entries, hottest first, until the cap: cutting between
  // entries keeps every line actionable (id + text) and the block
  // honest about what it dropped.
  // The cap bounds the WHOLE rendered block, wrapper included —
  // reserve room for it before filling entries.
  const wrapper = '<rolling-memory-hot>Remembered for this repository '
      '(hottest first; may be stale — verify before relying on it):\n'
      '\n'
      'Use memory_recall to search more; cite these ids when acting on '
      'them.</rolling-memory-hot>';
  final lines = <String>[];
  var budget = hotTierByteCap - wrapper.runes.length;
  var dropped = 0;
  for (final entry in hottest) {
    final line = render(entry);
    final cost = line.runes.length + 1; // + newline
    if (cost > budget) {
      dropped = hottest.length - lines.length;
      break;
    }
    lines.add(line);
    budget -= cost;
  }
  final omitted = dropped > 0
      ? '; $dropped older entr${dropped == 1 ? 'y' : 'ies'} omitted'
      : '';
  return '<rolling-memory-hot>Remembered for this repository '
      '(hottest first; may be stale — verify before relying on it'
      '$omitted):\n'
      '${lines.join('\n')}\n'
      'Use memory_recall to search more; cite these ids when acting on '
      'them.</rolling-memory-hot>';
}
